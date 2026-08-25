#!/usr/bin/env python3
import argparse
import json
import os
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_KNOWN_HOSTS = REPO_ROOT / "ansible" / "ssh_known_hosts"


REMOTE_SNAPSHOT_SCRIPT = r"""#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  printf '%s\n' '{"docker_available": false, "docker_accessible": false, "containers": []}'
  exit 0
fi

docker_cmd=(docker)
if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    docker_cmd=(sudo -n docker)
  else
    printf '%s\n' '{"docker_available": true, "docker_accessible": false, "containers": []}'
    exit 0
  fi
fi

mapfile -t ids < <("${docker_cmd[@]}" ps -aq --filter label=com.docker.compose.service)
if [ "${#ids[@]}" -eq 0 ]; then
  printf '%s\n' '{"docker_available": true, "docker_accessible": true, "containers": []}'
  exit 0
fi

printf '{"docker_available": true, "docker_accessible": true, "containers":'
"${docker_cmd[@]}" inspect "${ids[@]}"
printf '}\n'
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", default="ansible/inventory.ini")
    parser.add_argument("--target", required=True)
    parser.add_argument("--phase", default="unknown")
    parser.add_argument("--output")
    parser.add_argument(
        "--known-hosts",
        default=os.environ.get("ANSIBLE_KNOWN_HOSTS_FILE", str(DEFAULT_KNOWN_HOSTS)),
    )
    return parser.parse_args()


def load_inventory_entry(inventory_path: Path, target: str) -> dict[str, str]:
    if not inventory_path.is_file():
        raise FileNotFoundError(f"Inventory not found: {inventory_path}")

    with inventory_path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            stripped = raw_line.split("#", 1)[0].strip()
            if not stripped or stripped.startswith("["):
                continue
            parts = shlex.split(stripped)
            if not parts or parts[0] != target:
                continue

            values: dict[str, str] = {}
            for token in parts[1:]:
                if "=" not in token:
                    continue
                key, value = token.split("=", 1)
                values[key] = value
            return values

    raise KeyError(f"Target '{target}' not found in inventory {inventory_path}")


def normalize_key_path(raw_path: str) -> str:
    if not raw_path:
        return ""
    return str(Path(raw_path).expanduser())


def candidate_connections(target: str, entry: dict[str, str]) -> list[tuple[str, str]]:
    default_user = entry.get("ansible_user", "toomhorvath") or "toomhorvath"
    default_key = normalize_key_path(
        entry.get("ansible_ssh_private_key_file", "~/.ssh/toomhorvath")
    )

    candidates: list[tuple[str, str]] = []
    if target.endswith("-lxc"):
        candidates.append(("runner", normalize_key_path("~/.ssh/runner")))
    candidates.append((default_user, default_key))
    if default_user != "toomhorvath":
        candidates.append(("toomhorvath", normalize_key_path("~/.ssh/toomhorvath")))

    deduped: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for candidate in candidates:
        if not candidate[0] or not candidate[1]:
            continue
        if candidate in seen:
            continue
        seen.add(candidate)
        deduped.append(candidate)
    return deduped


def remote_snapshot(host: str, user: str, key_path: str, known_hosts_path: str) -> dict:
    key = Path(key_path).expanduser()
    if not key.is_file():
        raise FileNotFoundError(f"SSH key not found: {key}")
    known_hosts = Path(known_hosts_path).expanduser()
    if not known_hosts.is_file():
        raise FileNotFoundError(f"SSH known_hosts trust store not found: {known_hosts}")

    ssh_cmd = [
        "ssh",
        "-i",
        str(key),
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        f"UserKnownHostsFile={known_hosts}",
        "-o",
        "ConnectTimeout=10",
        f"{user}@{host}",
        "bash -s",
    ]
    result = subprocess.run(
        ssh_cmd,
        input=REMOTE_SNAPSHOT_SCRIPT,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        stderr = (
            (result.stderr or "").strip()
            or (result.stdout or "").strip()
            or "ssh failed"
        )
        raise RuntimeError(stderr)

    payload_text = (result.stdout or "").strip()
    if not payload_text:
        raise RuntimeError("remote snapshot returned no data")
    try:
        return json.loads(payload_text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid remote JSON: {exc}") from exc


def normalize_container(inspect_item: dict) -> dict:
    labels = (inspect_item.get("Config") or {}).get("Labels") or {}
    state = inspect_item.get("State") or {}
    return {
        "container_id": inspect_item.get("Id", ""),
        "name": (inspect_item.get("Name") or "").lstrip("/"),
        "service": labels.get("com.docker.compose.service", ""),
        "project": labels.get("com.docker.compose.project", ""),
        "image": ((inspect_item.get("Config") or {}).get("Image") or ""),
        "image_id": inspect_item.get("Image", ""),
        "status": state.get("Status", ""),
        "running": bool(state.get("Running")),
        "started_at": state.get("StartedAt", ""),
        "finished_at": state.get("FinishedAt", ""),
    }


def build_snapshot(args: argparse.Namespace) -> dict:
    inventory_path = Path(args.inventory)
    entry = load_inventory_entry(inventory_path, args.target)
    host = entry.get("ansible_host", args.target) or args.target

    errors: list[str] = []
    payload: dict | None = None
    connection_user = ""
    connection_key = ""

    for user, key in candidate_connections(args.target, entry):
        try:
            payload = remote_snapshot(host, user, key, args.known_hosts)
            connection_user = user
            connection_key = key
            break
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{user}@{host} via {Path(key).name}: {exc}")

    snapshot = {
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "phase": args.phase,
        "target": args.target,
        "host": host,
        "reachable": payload is not None,
        "connection_user": connection_user,
        "connection_key": connection_key,
        "docker_available": False,
        "docker_accessible": False,
        "containers": [],
        "errors": errors,
    }

    if payload is None:
        return snapshot

    raw_containers = payload.get("containers") or []
    if not isinstance(raw_containers, list):
        raw_containers = []

    snapshot["docker_available"] = bool(payload.get("docker_available"))
    snapshot["docker_accessible"] = bool(payload.get("docker_accessible"))
    snapshot["containers"] = sorted(
        (
            normalize_container(item)
            for item in raw_containers
            if isinstance(item, dict)
        ),
        key=lambda item: (
            item.get("project", ""),
            item.get("service", ""),
            item.get("name", ""),
        ),
    )
    return snapshot


def main() -> int:
    args = parse_args()
    try:
        snapshot = build_snapshot(args)
    except Exception as exc:  # noqa: BLE001
        print(str(exc), file=sys.stderr)
        return 1

    rendered = json.dumps(snapshot, indent=2, sort_keys=True)
    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
