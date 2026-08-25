#!/usr/bin/env python3
import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

MAX_MESSAGE_LEN = 3900
SKIP_STEP_NAMES = {"Complete job"}
DEPLOY_WORKFLOW_NAMES = {"Platform / Deploy"}
SUCCESS_CONCLUSIONS = {"success", "neutral", "skipped"}


def load_json(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def iso_to_local(ts: str) -> str:
    if not ts:
        return "unknown"
    parsed = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return parsed.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")


def duration_seconds(started_at: str, completed_at: str) -> str:
    if not started_at or not completed_at:
        return "unknown"
    start = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
    end = datetime.fromisoformat(completed_at.replace("Z", "+00:00"))
    seconds = max(0, int((end - start).total_seconds()))
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes}m {seconds}s"
    if minutes:
        return f"{minutes}m {seconds}s"
    return f"{seconds}s"


def upper_status(value: str) -> str:
    if not value:
        return "UNKNOWN"
    return value.replace("_", " ").upper()


def truncate(text: str) -> str:
    if len(text) <= MAX_MESSAGE_LEN:
        return text
    return text[: MAX_MESSAGE_LEN - 14] + "\n\n(truncated)"


def telegram_post(token: str, chat_id: str, text: str) -> None:
    payload = urllib.parse.urlencode(
        {
            "chat_id": chat_id,
            "text": truncate(text),
            "disable_web_page_preview": "true",
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=payload,
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        response.read()


def build_summary_message(event: dict, jobs: list[dict]) -> str:
    workflow = event["workflow_run"]
    conclusion = workflow.get("conclusion") or workflow.get("status") or "unknown"
    counts: dict[str, int] = {}
    for job in jobs:
        job_conclusion = (
            job.get("conclusion") or job.get("status") or "unknown"
        ).lower()
        counts[job_conclusion] = counts.get(job_conclusion, 0) + 1

    count_bits = [f"{status}={counts[status]}" for status in sorted(counts)]
    pr_numbers = [
        str(pr["number"])
        for pr in workflow.get("pull_requests", [])
        if pr.get("number")
    ]

    lines = [
        f"WORKFLOW {upper_status(conclusion)}: {workflow.get('name', 'unknown')}",
        f"repo: {workflow['repository']['full_name']}",
        f"branch: {workflow.get('head_branch') or 'unknown'}",
        f"event: {workflow.get('event') or 'unknown'}",
        f"actor: {workflow.get('actor', {}).get('login') or 'unknown'}",
        f"sha: {(workflow.get('head_sha') or '')[:7] or 'unknown'}",
        f"run: #{workflow.get('run_number', 'unknown')} attempt {workflow.get('run_attempt', 'unknown')}",
        f"started: {iso_to_local(workflow.get('created_at') or '')}",
        f"finished: {iso_to_local(workflow.get('updated_at') or '')}",
        f"duration: {duration_seconds(workflow.get('run_started_at') or workflow.get('created_at') or '', workflow.get('updated_at') or '')}",
        f"jobs: {', '.join(count_bits) if count_bits else 'none'}",
    ]
    if pr_numbers:
        lines.append(f"pull_request: #{', #'.join(pr_numbers)}")
    lines.append(f"url: {workflow.get('html_url') or 'unknown'}")
    return "\n".join(lines)


def build_job_message(event: dict, job: dict) -> str:
    workflow = event["workflow_run"]
    conclusion = job.get("conclusion") or job.get("status") or "unknown"

    lines = [
        f"JOB {upper_status(conclusion)}: {job.get('name') or 'unknown'}",
        f"workflow: {workflow.get('name', 'unknown')}",
        f"branch: {workflow.get('head_branch') or 'unknown'}",
        f"sha: {(workflow.get('head_sha') or '')[:7] or 'unknown'}",
        f"runner: {job.get('runner_name') or 'github-hosted'}",
        f"started: {iso_to_local(job.get('started_at') or '')}",
        f"finished: {iso_to_local(job.get('completed_at') or '')}",
        f"duration: {duration_seconds(job.get('started_at') or '', job.get('completed_at') or '')}",
        "steps:",
    ]

    steps = job.get("steps") or []
    for step in steps:
        name = (step.get("name") or "").strip()
        if not name or name in SKIP_STEP_NAMES:
            continue
        step_conclusion = step.get("conclusion") or step.get("status") or "unknown"
        number = step.get("number")
        if number is None:
            lines.append(f"- {step_conclusion}: {name}")
        else:
            lines.append(f"{number}. {step_conclusion}: {name}")

    lines.append(f"url: {job.get('html_url') or workflow.get('html_url') or 'unknown'}")
    return "\n".join(lines)


def build_failure_job_message(event: dict, job: dict) -> str:
    workflow = event["workflow_run"]
    conclusion = job.get("conclusion") or job.get("status") or "unknown"

    lines = [
        f"JOB {upper_status(conclusion)}: {job.get('name') or 'unknown'}",
        f"workflow: {workflow.get('name', 'unknown')}",
        f"branch: {workflow.get('head_branch') or 'unknown'}",
        f"sha: {(workflow.get('head_sha') or '')[:7] or 'unknown'}",
    ]

    failing_steps = []
    for step in job.get("steps") or []:
        name = (step.get("name") or "").strip()
        if not name or name in SKIP_STEP_NAMES:
            continue
        step_conclusion = (
            step.get("conclusion") or step.get("status") or "unknown"
        ).lower()
        if step_conclusion in SUCCESS_CONCLUSIONS:
            continue
        number = step.get("number")
        if number is None:
            failing_steps.append(f"- {step_conclusion}: {name}")
        else:
            failing_steps.append(f"{number}. {step_conclusion}: {name}")

    if failing_steps:
        lines.append("failing steps:")
        lines.extend(failing_steps)
    else:
        lines.append("failing steps: none recorded")

    lines.append(f"url: {job.get('html_url') or workflow.get('html_url') or 'unknown'}")
    return "\n".join(lines)


def workflow_conclusion(event: dict) -> str:
    workflow = event["workflow_run"]
    return (workflow.get("conclusion") or workflow.get("status") or "unknown").lower()


def should_notify_workflow(event: dict) -> bool:
    workflow = event["workflow_run"]
    name = workflow.get("name") or ""
    conclusion = workflow_conclusion(event)
    if conclusion not in SUCCESS_CONCLUSIONS:
        return True
    if name in DEPLOY_WORKFLOW_NAMES:
        return False
    return False


def build_messages_for_workflow(event: dict, jobs: list[dict]) -> list[str]:
    if not should_notify_workflow(event):
        return []

    messages = [build_summary_message(event, jobs)]
    for job in jobs:
        conclusion = (job.get("conclusion") or job.get("status") or "unknown").lower()
        if conclusion in SUCCESS_CONCLUSIONS:
            continue
        messages.append(build_failure_job_message(event, job))
    return messages


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event")
    parser.add_argument("--jobs")
    parser.add_argument("--message-file")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    token = os.environ.get("ACTIONS_TELEGRAM_BOT_TOKEN", "").strip()
    chat_id = os.environ.get("ACTIONS_TELEGRAM_CHAT_ID", "").strip()
    if not args.dry_run and (not token or not chat_id):
        print(
            "Telegram secrets not configured; skipping notification.", file=sys.stderr
        )
        return 0

    if args.message_file:
        messages = [Path(args.message_file).read_text(encoding="utf-8").strip()]
    else:
        if not args.event or not args.jobs:
            parser.error(
                "--event and --jobs are required unless --message-file is provided"
            )
        event = load_json(args.event)
        jobs_payload = load_json(args.jobs)
        jobs = jobs_payload.get("jobs") or []

        messages = build_messages_for_workflow(event, jobs)

    if args.dry_run:
        for index, message in enumerate(messages, start=1):
            print(f"--- message {index} ---")
            print(message)
        return 0

    if not messages:
        return 0

    for message in messages:
        telegram_post(token, chat_id, message)

    return 0


if __name__ == "__main__":
    sys.exit(main())
