#!/usr/bin/env python3
"""Run audit/cleanup across pve, running LXCs, and running VMs from Proxmox."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections.abc import Iterable
from dataclasses import dataclass

PAYLOAD = r"""#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

MODE="{{MODE}}"
JOURNAL_VACUUM_SIZE="{{JOURNAL_VACUUM_SIZE}}"
TMP_MAX_AGE_DAYS="{{TMP_MAX_AGE_DAYS}}"

bytes() {
  local path="$1"
  if [ -e "$path" ]; then
    du -sxb "$path" 2>/dev/null | awk '{print $1}'
  else
    echo 0
  fi
}

sum_paths() {
  local total=0
  local value=0
  local path=""
  for path in "$@"; do
    [ -e "$path" ] || continue
    value=$(du -sxb "$path" 2>/dev/null | awk '{print $1}' || echo 0)
    total=$((total + value))
  done
  echo "$total"
}

docker_reclaim_bytes() {
  if ! command -v docker >/dev/null 2>&1; then
    echo 0
    return 0
  fi

  docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null | while IFS='|' read -r type reclaim; do
    [ "$type" = "Images" ] || continue
    reclaim="${reclaim%% *}"
    reclaim="${reclaim%B}"
    if [ -n "$reclaim" ] && [ "$reclaim" != "0" ]; then
      numfmt --from=si "$reclaim" 2>/dev/null || echo 0
    else
      echo 0
    fi
    break
  done
}

audit_fields() {
  local root_size root_used root_avail
  read -r root_size root_used root_avail < <(df -B1 --output=size,used,avail / | tail -1)
  local apt_cache apt_lists journal_bytes tmp_bytes var_tmp user_cache trash docker_reclaim
  apt_cache=$(bytes /var/cache/apt)
  apt_lists=$(bytes /var/lib/apt/lists)
  journal_bytes=$(bytes /var/log/journal)
  tmp_bytes=$(bytes /tmp)
  var_tmp=$(bytes /var/tmp)
  user_cache=$(sum_paths /root/.cache /home/*/.cache)
  trash=$(sum_paths /root/.local/share/Trash /home/*/.local/share/Trash)
  docker_reclaim=$(docker_reclaim_bytes)

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$root_size" "$root_used" "$root_avail" "$apt_cache" "$apt_lists" "$journal_bytes" \
    "$tmp_bytes" "$var_tmp" "$user_cache" "$trash" "$docker_reclaim"
}

cleanup_now() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get clean >/dev/null 2>&1 || true
    rm -rf /var/lib/apt/lists/* 2>/dev/null || true
  fi

  if command -v journalctl >/dev/null 2>&1; then
    journalctl --vacuum-size="$JOURNAL_VACUUM_SIZE" >/dev/null 2>&1 || true
  fi

  local dir=""
  for dir in /tmp /var/tmp; do
    [ -d "$dir" ] || continue
    find "$dir" -mindepth 1 -xdev -mtime +"$TMP_MAX_AGE_DAYS" -print0 2>/dev/null | xargs -0r rm -rf -- 2>/dev/null || true
  done

  if command -v docker >/dev/null 2>&1; then
    # label!= excludes locally-built one-shot images (e.g. jobs-refresh on
    # 01-myapps-vm): they are unreferenced between timer fires but cannot be
    # re-pulled from any registry, so pruning them breaks the next run.
    # Keep the key in sync with the LABEL in jobs-refresh.Dockerfile.j2.
    docker image prune -af --filter "label!=homelab.prune-keep" >/dev/null 2>&1 || true
    docker builder prune -af >/dev/null 2>&1 || true
  fi

  rm -rf /root/.cache/pip /root/.cache/whisper /home/*/.cache/pip /home/*/.cache/whisper 2>/dev/null || true
}

if [ "$MODE" = "clean" ]; then
  before_used=$(df -B1 --output=used / | tail -1 | tr -d ' ')
  cleanup_now
  after_used=$(df -B1 --output=used / | tail -1 | tr -d ' ')
  reclaimed=$((before_used - after_used))
  read -r root_size root_used root_avail < <(df -B1 --output=size,used,avail / | tail -1)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$before_used" "$after_used" "$reclaimed" "$root_size" "$root_used" "$root_avail"
else
  audit_fields
fi
"""


@dataclass
class Target:
    vmid: int
    name: str
    kind: str


@dataclass
class CleanupResult:
    target: Target
    before_used: int
    after_used: int
    reclaimed: int
    root_size: int
    root_used: int
    root_avail: int


@dataclass
class AuditResult:
    target: Target
    root_size: int
    root_used: int
    root_avail: int
    apt_cache: int
    apt_lists: int
    journal: int
    tmp: int
    var_tmp: int
    user_cache: int
    trash: int
    docker_reclaim: int

    @property
    def non_docker_remaining(self) -> int:
        return (
            self.apt_cache
            + self.apt_lists
            + self.journal
            + self.tmp
            + self.var_tmp
            + self.user_cache
            + self.trash
        )


def human_bytes(value: int) -> str:
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    size = float(value)
    for unit in units:
        if abs(size) < 1024 or unit == units[-1]:
            return f"{int(size)}B" if unit == "B" else f"{size:.1f}{unit}"
        size /= 1024.0
    return f"{value}B"


def run(
    command: list[str], *, input_text: str | None = None, check: bool = True
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        input=input_text,
        text=True,
        capture_output=True,
        check=check,
    )


def payload_for(mode: str, journal_vacuum_size: str, tmp_max_age_days: int) -> str:
    return (
        PAYLOAD.replace("{{MODE}}", mode)
        .replace("{{JOURNAL_VACUUM_SIZE}}", journal_vacuum_size)
        .replace("{{TMP_MAX_AGE_DAYS}}", str(tmp_max_age_days))
    )


def list_running_lxcs() -> list[Target]:
    proc = run(["pct", "list"])
    targets: list[Target] = []
    for line in proc.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 3 or parts[1] != "running":
            continue
        targets.append(Target(vmid=int(parts[0]), name=parts[2], kind="lxc"))
    return targets


def list_running_vms() -> list[Target]:
    proc = run(["qm", "list"])
    targets: list[Target] = []
    for line in proc.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 3 or parts[2] != "running":
            continue
        targets.append(Target(vmid=int(parts[0]), name=parts[1], kind="vm"))
    return targets


def parse_guest_exec_json(stdout: str) -> str:
    obj = json.loads(stdout)
    exitcode = int(obj.get("exitcode", 1))
    if exitcode != 0:
        err = obj.get("err-data", "").strip()
        raise RuntimeError(err or f"guest command failed with exit code {exitcode}")
    return obj.get("out-data", "")


def run_on_pve(payload: str) -> str:
    return run(["bash", "-s"], input_text=payload).stdout


def run_on_lxc(vmid: int, payload: str) -> str:
    return run(
        ["pct", "exec", str(vmid), "--", "bash", "-s"], input_text=payload
    ).stdout


def run_on_vm(vmid: int, payload: str) -> str:
    run(["qm", "agent", str(vmid), "ping"])
    proc = run(
        [
            "qm",
            "guest",
            "exec",
            str(vmid),
            "--timeout",
            "600",
            "--pass-stdin",
            "1",
            "--",
            "bash",
            "-s",
        ],
        input_text=payload,
    )
    return parse_guest_exec_json(proc.stdout)


def exec_target(target: Target, payload: str) -> str:
    if target.kind == "host":
        return run_on_pve(payload)
    if target.kind == "lxc":
        return run_on_lxc(target.vmid, payload)
    if target.kind == "vm":
        return run_on_vm(target.vmid, payload)
    raise ValueError(f"unsupported target kind: {target.kind}")


def parse_cleanup_result(target: Target, output: str) -> CleanupResult:
    line = output.strip().splitlines()[-1]
    parts = line.split("\t")
    if len(parts) != 6:
        raise RuntimeError(f"{target.name}: unexpected cleanup output: {line!r}")
    values = list(map(int, parts))
    return CleanupResult(target, *values)


def parse_audit_result(target: Target, output: str) -> AuditResult:
    line = output.strip().splitlines()[-1]
    parts = line.split("\t")
    if len(parts) != 11:
        raise RuntimeError(f"{target.name}: unexpected audit output: {line!r}")
    values = list(map(int, parts))
    return AuditResult(target, *values)


def print_cleanup(results: Iterable[CleanupResult]) -> None:
    total = 0
    print("Cleanup Summary")
    for item in results:
        total += item.reclaimed
        print(
            f"{item.target.name:22} {item.target.kind:4} "
            f"reclaimed={human_bytes(item.reclaimed):>8} "
            f"used={human_bytes(item.root_used):>8}/{human_bytes(item.root_size):<8} "
            f"free={human_bytes(item.root_avail):>8}"
        )
    print(f"Total reclaimed: {human_bytes(total)}")


def print_audit(results: Iterable[AuditResult]) -> None:
    total = 0
    print("Audit Summary")
    for item in results:
        total += item.non_docker_remaining
        print(
            f"{item.target.name:22} {item.target.kind:4} "
            f"root_used={human_bytes(item.root_used):>8}/{human_bytes(item.root_size):<8} "
            f"free={human_bytes(item.root_avail):>8} "
            f"remaining={human_bytes(item.non_docker_remaining):>8}"
        )
    print(f"Total remaining non-Docker leftovers: {human_bytes(total)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["audit", "clean"], nargs="?", default="audit")
    parser.add_argument("--journal-vacuum-size", default="100M")
    parser.add_argument("--tmp-max-age-days", type=int, default=7)
    args = parser.parse_args()

    if os.geteuid() != 0:
        print("Run this script as root on the Proxmox host.", file=sys.stderr)
        return 1

    payload = payload_for(args.mode, args.journal_vacuum_size, args.tmp_max_age_days)
    targets: list[Target] = [Target(vmid=0, name="pve", kind="host")]
    targets.extend(sorted(list_running_lxcs(), key=lambda item: item.name))
    targets.extend(sorted(list_running_vms(), key=lambda item: item.name))

    cleanup_results: list[CleanupResult] = []
    audit_results: list[AuditResult] = []

    for target in targets:
        try:
            output = exec_target(target, payload)
            if args.mode == "clean":
                cleanup_results.append(parse_cleanup_result(target, output))
            else:
                audit_results.append(parse_audit_result(target, output))
        # Deliberately broad: one unreachable or misbehaving guest must not
        # abort the sweep over the rest of the fleet. The failure is reported
        # per target and the loop continues.
        except Exception as exc:  # noqa: BLE001
            print(f"{target.name}: {exc}", file=sys.stderr)

    if args.mode == "clean":
        print_cleanup(cleanup_results)
    else:
        print_audit(audit_results)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
