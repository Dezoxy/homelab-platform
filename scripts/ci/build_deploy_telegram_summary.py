#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path

ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
TASK_RE = re.compile(r"TASK \[(.+?)\] \*+")
CHANGED_RE = re.compile(r"changed:\s+\[([^\]]+)\]")
RECAP_RE = re.compile(
    r"([^\s:]+)\s*:\s*ok=(\d+)\s+changed=(\d+)\s+unreachable=(\d+)\s+failed=(\d+)\s+skipped=(\d+)\s+rescued=(\d+)\s+ignored=(\d+)"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    parser.add_argument("--deployment-mode", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--actor", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run-url", required=True)
    parser.add_argument("--before")
    parser.add_argument("--after")
    parser.add_argument("--ansible-log")
    parser.add_argument("--output")
    return parser.parse_args()


def load_snapshot(path: str | None) -> dict:
    if not path:
        return {}
    snapshot_path = Path(path)
    if not snapshot_path.is_file():
        return {}
    with snapshot_path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def service_key(item: dict) -> str:
    project = item.get("project") or ""
    service = item.get("service") or ""
    name = item.get("name") or ""
    if project and service:
        return f"{project}/{service}"
    if service:
        return service
    if name:
        return name
    return item.get("container_id") or "unknown"


def service_label(item: dict) -> str:
    service = item.get("service") or ""
    project = item.get("project") or ""
    name = item.get("name") or ""
    if service:
        return service if not project else f"{project}/{service}"
    if name:
        return name
    return "unknown"


def compact_image(image: str) -> str:
    return image or "unknown"


def snapshot_ready(snapshot: dict) -> bool:
    return bool(
        snapshot
        and snapshot.get("reachable")
        and snapshot.get("docker_available")
        and snapshot.get("docker_accessible")
    )


def summarize_changes(before: dict, after: dict) -> list[str]:
    before_items = {
        service_key(item): item
        for item in (before.get("containers") or [])
        if isinstance(item, dict)
    }
    after_items = {
        service_key(item): item
        for item in (after.get("containers") or [])
        if isinstance(item, dict)
    }

    changes: list[str] = []
    for key in sorted(set(before_items) | set(after_items)):
        old = before_items.get(key)
        new = after_items.get(key)
        if old is None and new is not None:
            changes.append(
                f"- {service_label(new)}: created; image {compact_image(new.get('image', ''))}"
            )
            continue
        if old is not None and new is None:
            changes.append(
                f"- {service_label(old)}: removed; previous image {compact_image(old.get('image', ''))}"
            )
            continue
        assert old is not None and new is not None
        parts: list[str] = []
        if old.get("image") != new.get("image"):
            parts.append(
                f"image {compact_image(old.get('image', ''))} -> {compact_image(new.get('image', ''))}"
            )
        else:
            parts.append(f"image {compact_image(new.get('image', ''))}")
        if old.get("container_id") != new.get("container_id"):
            parts.append("recreated")
        if old.get("status") != new.get("status"):
            parts.append(
                f"status {old.get('status') or 'unknown'} -> {new.get('status') or 'unknown'}"
            )
        if len(parts) == 1 and parts[0].startswith("image "):
            continue
        changes.append(f"- {service_label(new)}: {'; '.join(parts)}")

    return changes


def summarize_current_services(snapshot: dict) -> list[str]:
    items = [
        item for item in (snapshot.get("containers") or []) if isinstance(item, dict)
    ]
    return [
        f"- {service_label(item)}: image {compact_image(item.get('image', ''))}"
        for item in sorted(items, key=lambda item: service_label(item))
    ]


def snapshot_note(prefix: str, snapshot: dict) -> str | None:
    if not snapshot:
        return f"{prefix}: unavailable"
    if not snapshot.get("reachable"):
        errors = snapshot.get("errors") or []
        detail = errors[0] if errors else "ssh failed"
        return f"{prefix}: unreachable ({detail})"
    if not snapshot.get("docker_available"):
        return f"{prefix}: docker not installed"
    if not snapshot.get("docker_accessible"):
        return f"{prefix}: docker not accessible"
    return None


def load_text(path: str | None) -> str:
    if not path:
        return ""
    text_path = Path(path)
    if not text_path.is_file():
        return ""
    return text_path.read_text(encoding="utf-8", errors="replace")


def parse_ansible_log(log_text: str, target: str) -> dict:
    if not log_text:
        return {}

    current_task = ""
    changed_tasks: list[str] = []
    seen_tasks: set[str] = set()
    recap: dict | None = None

    for raw_line in log_text.splitlines():
        line = ANSI_ESCAPE_RE.sub("", raw_line).strip()
        if not line:
            continue

        task_match = TASK_RE.search(line)
        if task_match:
            current_task = task_match.group(1).strip()
            continue

        changed_match = CHANGED_RE.search(line)
        if changed_match and changed_match.group(1).strip() == target and current_task:
            if current_task not in seen_tasks:
                seen_tasks.add(current_task)
                changed_tasks.append(current_task)
            continue

        recap_match = RECAP_RE.search(line)
        if recap_match and recap_match.group(1).strip() == target:
            recap = {
                "ok": int(recap_match.group(2)),
                "changed": int(recap_match.group(3)),
                "unreachable": int(recap_match.group(4)),
                "failed": int(recap_match.group(5)),
                "skipped": int(recap_match.group(6)),
                "rescued": int(recap_match.group(7)),
                "ignored": int(recap_match.group(8)),
            }

    return {
        "changed_tasks": changed_tasks,
        "recap": recap or {},
    }


def prioritize_changed_tasks(tasks: list[str]) -> list[str]:
    if not tasks:
        return []

    highlight_keywords = (
        "gemini",
        "codex",
        "docker",
        "compose",
        "sandbox",
        "systemd",
        "service",
        "gateway",
    )
    deferred_prefixes = ("observability_agent :",)

    ranked: list[tuple[int, int, str]] = []
    for index, task in enumerate(tasks):
        task_lower = task.lower()
        score = 0
        if any(keyword in task_lower for keyword in highlight_keywords):
            score += 10
        if task.startswith(deferred_prefixes):
            score -= 5
        ranked.append((-score, index, task))

    return [task for _, _, task in sorted(ranked)]


def build_message(
    args: argparse.Namespace, before: dict, after: dict, ansible_log: dict
) -> str:
    status = (args.status or "unknown").replace("_", " ").upper()
    lines = [
        f"DEPLOY TARGET {status}: {args.target}",
        f"workflow: {args.workflow}",
        f"repo: {args.repo}",
        f"branch: {args.branch}",
        f"actor: {args.actor}",
        f"sha: {(args.sha or '')[:7] or 'unknown'}",
        f"mode: {args.deployment_mode}",
    ]

    before_note = snapshot_note("before", before)
    after_note = snapshot_note("after", after)
    if before_note:
        lines.append(before_note)
    if after_note:
        lines.append(after_note)

    recap = ansible_log.get("recap") or {}
    if recap:
        lines.append(
            "ansible recap: "
            f"changed={recap.get('changed', 0)} "
            f"failed={recap.get('failed', 0)} "
            f"unreachable={recap.get('unreachable', 0)}"
        )

    changed_tasks = ansible_log.get("changed_tasks") or []
    if changed_tasks:
        lines.append("ansible changed tasks:")
        preview = prioritize_changed_tasks(changed_tasks)[:8]
        lines.extend(f"- {task}" for task in preview)
        remaining = len(changed_tasks) - len(preview)
        if remaining > 0:
            lines.append(f"- ... and {remaining} more")

    if snapshot_ready(before) and snapshot_ready(after):
        changes = summarize_changes(before, after)
        if changes:
            lines.append("compose services changed:")
            lines.extend(changes)
        else:
            after_containers = after.get("containers") or []
            if after_containers:
                lines.append("compose services changed: none detected")
            else:
                lines.append(
                    "compose services changed: none detected or no compose services present"
                )
    elif snapshot_ready(after):
        current = summarize_current_services(after)
        lines.append(
            "compose change diff: unavailable (no comparable pre-deploy snapshot)"
        )
        if current:
            lines.append("observed compose images after deploy:")
            lines.extend(current)
        else:
            lines.append("observed compose images after deploy: none")
    else:
        lines.append("compose change diff: unavailable")

    lines.append(f"url: {args.run_url}")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    before = load_snapshot(args.before)
    after = load_snapshot(args.after)
    ansible_log = parse_ansible_log(load_text(args.ansible_log), args.target)
    message = build_message(args, before, after, ansible_log)

    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(message + "\n", encoding="utf-8")
    else:
        print(message)
    return 0


if __name__ == "__main__":
    sys.exit(main())
