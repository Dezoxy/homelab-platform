#!/usr/bin/env python3
"""Pre-flight check for a UniFi controller migration: is the backup restorable?

A UniFi `.unf` backup cannot be restored into a Network version *older* than the
one that produced it. That makes the version delta the one cheap check standing
between a 15-minute controller swap and rebuilding the site by hand.

Reads the newest autobackup's recorded version off 01-unifi-vm and compares it
against the Network version of the controller you intend to restore into (read
that off the target's UI -- on UniFi OS Server it is under Settings > System).

    scripts/ops/unifi_backup_version_check.py 10.4.57

Exit status is the gate: 0 = safe to restore, 1 = not safe, 2 = could not tell.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass

DEFAULT_HOST = "192.168.1.75"
DEFAULT_USER = "toomhorvath"
DEFAULT_KEY = "~/.ssh/toomhorvath"
# UniFi OS Server keeps its data in a rootless Podman volume owned by the
# `uosserver` user, and the files inside are owned by the container's uid --
# hence the sudo below. The layout under _data mirrors the retired LXC's
# /config/data exactly, so this is the same autobackup_meta.json as before.
DEFAULT_META = (
    "/home/uosserver/.local/share/containers/storage/volumes"
    "/uosserver_var_lib_unifi/_data/backup/autobackup/autobackup_meta.json"
)

OK, BLOCKED, UNKNOWN = 0, 1, 2


@dataclass(frozen=True)
class Backup:
    """One entry from autobackup_meta.json."""

    filename: str
    version: str
    when: str
    time: int


def parse_version(raw: str) -> tuple[int, ...]:
    """'10.4.57.0-g19f85adec' -> (10, 4, 57, 0). Trailing build metadata is dropped."""
    head = raw.strip().lstrip("vV").split("-", 1)[0]
    parts: list[int] = []
    for chunk in head.split("."):
        if not chunk.isdigit():
            break
        parts.append(int(chunk))
    if not parts:
        raise ValueError(f"not a version string: {raw!r}")
    return tuple(parts)


def fetch_meta(host: str, user: str, key: str, path: str) -> dict:
    """cat the autobackup metadata over SSH and parse it."""
    proc = subprocess.run(
        [
            "ssh",
            "-i",
            key,
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "ConnectTimeout=10",
            f"{user}@{host}",
            f"sudo cat {path}",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"ssh {user}@{host} failed: {proc.stderr.strip()}")
    return json.loads(proc.stdout)


def newest_backup(meta: dict) -> Backup:
    """The most recent autobackup -- the one a migration would actually restore."""
    entries = [
        Backup(
            filename=entry.get("filename", name),
            version=str(entry["version"]),
            when=str(entry.get("datetime", "?")),
            time=int(entry.get("time", 0)),
        )
        for name, entry in meta.items()
        if isinstance(entry, dict) and "version" in entry
    ]
    if not entries:
        raise RuntimeError("no versioned backups in metadata")
    return max(entries, key=lambda b: b.time)


def classify(source: tuple[int, ...], target: tuple[int, ...]) -> tuple[int, str, str]:
    """Decide whether restoring `source` into `target` is safe.

    Conservative default: equal or newer target is fine, older is blocked. A
    major-version jump is allowed but called out, because the restore triggers a
    one-way schema migration -- you cannot roll the .unf back afterwards.
    """
    if target < source:
        return (
            BLOCKED,
            "BLOCKED",
            (
                "Target is older than the backup. UniFi refuses this restore. "
                "Upgrade the target's Network version first."
            ),
        )
    if target == source:
        return OK, "OK", "Exact version match -- cleanest possible restore."
    if target[0] > source[0]:
        return (
            OK,
            "OK (major jump)",
            (
                f"Target is a major version ahead ({source[0]}.x -> {target[0]}.x). "
                "Supported, but the restore migrates the schema one-way: keep the old "
                "controller running until the APs reconnect."
            ),
        )
    return OK, "OK", "Target is newer; the restore will migrate the schema forward."


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "target_version", help="Network version on the controller you will restore INTO"
    )
    ap.add_argument(
        "--host", default=DEFAULT_HOST, help=f"controller host (default {DEFAULT_HOST})"
    )
    ap.add_argument("--user", default=DEFAULT_USER)
    ap.add_argument("--key", default=DEFAULT_KEY)
    ap.add_argument("--meta-path", default=DEFAULT_META)
    args = ap.parse_args()

    try:
        target = parse_version(args.target_version)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return UNKNOWN

    try:
        backup = newest_backup(
            fetch_meta(args.host, args.user, args.key, args.meta_path)
        )
        source = parse_version(backup.version)
    except (RuntimeError, json.JSONDecodeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return UNKNOWN

    code, verdict, detail = classify(source, target)

    print(f"newest backup : {backup.filename}")
    print(f"taken         : {backup.when}")
    print(f"produced by   : Network {backup.version}")
    print(f"restoring into: Network {args.target_version}")
    print()
    print(f"{verdict}: {detail}")
    return code


if __name__ == "__main__":
    sys.exit(main())
