#!/usr/bin/env python3
"""Build temporary guest SSH trust through the pinned Proxmox host."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path


class GuestNotProvisioned(Exception):
    """The guest is declared in the repo but does not exist on the node yet.

    Distinct from every other attestation failure on purpose. Inventory here is
    GENERATED from Terraform variable defaults
    (scripts/setup/generate-inventory.py), so a stack that has been committed
    but not yet applied legitimately appears in ansible/inventory.ini with no
    Proxmox guest behind it. Treating that as fatal made a single unapplied
    stack break `make ping` for the entire fleet.

    Only "the config file does not exist" is treated this way. A guest that
    exists but will not give up its host key still aborts, because that is
    indistinguishable from something being wrong.
    """


REPO_ROOT = Path(__file__).resolve().parents[2]
GUEST_INVENTORY = REPO_ROOT / "ansible" / "inventory.ini"
PVE_INVENTORY = REPO_ROOT / "ansible" / "inventory-proxmox.ini"
ROOT_KNOWN_HOSTS = REPO_ROOT / "ansible" / "ssh_known_hosts"
ATTESTATION_MAP = REPO_ROOT / "ansible" / "proxmox_guest_ssh_attestation.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--target", action="append", dest="targets")
    selection.add_argument("--limit", help="Ansible host pattern separated by ':'")
    selection.add_argument("--all", action="store_true", dest="all_targets")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--attempts",
        type=int,
        default=int(os.environ.get("SSH_TRUST_ATTEST_ATTEMPTS", "24")),
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=float(os.environ.get("SSH_TRUST_ATTEST_DELAY", "5")),
    )
    return parser.parse_args()


def load_inventory(path: Path) -> dict[str, dict[str, str]]:
    hosts: dict[str, dict[str, str]] = {}
    section = ""
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if section.endswith((":children", ":vars")):
            continue
        tokens = shlex.split(line)
        variables = dict(token.split("=", 1) for token in tokens[1:] if "=" in token)
        hosts[tokens[0]] = variables
    return hosts


def requested_targets(args: argparse.Namespace, mapping: dict[str, dict]) -> list[str]:
    if args.all_targets:
        return list(mapping)
    if args.limit:
        targets = [target.strip() for target in args.limit.split(":") if target.strip()]
    else:
        targets = args.targets or []
    unknown = sorted(set(targets) - set(mapping))
    if unknown:
        raise ValueError(f"Unknown attested guest target(s): {', '.join(unknown)}")
    return list(dict.fromkeys(targets))


def public_key_line(payload: str, target: str) -> tuple[str, str]:
    for line in payload.splitlines():
        tokens = line.strip().split()
        if len(tokens) >= 2 and tokens[0] == "ssh-ed25519":
            return tokens[0], tokens[1]
    raise ValueError(f"No Ed25519 host public key returned for {target}")


def fetch_from_pve(
    pve: dict[str, str], metadata: dict, target: str, attempts: int, delay: float
) -> tuple[str, str]:
    host = pve.get("ansible_host", "pve")
    user = pve.get("ansible_user", "toomhorvath")
    key_path = str(
        Path(pve.get("ansible_ssh_private_key_file", "~/.ssh/toomhorvath")).expanduser()
    )
    vmid = str(metadata["vmid"])
    if metadata["kind"] == "lxc":
        expected_name = shlex.quote(f"hostname: {target}")
        remote_command = (
            f"set -euo pipefail; sudo -n pct config {vmid} | grep -Fx -- {expected_name} >/dev/null; "
            f"sudo -n pct exec {vmid} -- cat /etc/ssh/ssh_host_ed25519_key.pub"
        )
    else:
        expected_name = shlex.quote(f"name: {target}")
        remote_command = (
            f"set -euo pipefail; sudo -n qm config {vmid} | grep -Fx -- {expected_name} >/dev/null; "
            f"sudo -n qm guest exec {vmid} --timeout 30 -- cat /etc/ssh/ssh_host_ed25519_key.pub"
        )

    command = [
        "ssh",
        "-i",
        key_path,
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        f"UserKnownHostsFile={ROOT_KNOWN_HOSTS}",
        "-o",
        "ConnectTimeout=10",
        f"{user}@{host}",
        remote_command,
    ]
    last_error = ""
    for attempt in range(1, attempts + 1):
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        if result.returncode == 0:
            try:
                payload = result.stdout
                if metadata["kind"] == "vm":
                    response = json.loads(payload)
                    if response.get("exitcode") != 0:
                        raise ValueError(
                            f"guest agent command exited {response.get('exitcode')}"
                        )
                    payload = response.get("out-data", "")
                return public_key_line(payload, target)
            except (ValueError, json.JSONDecodeError) as exc:
                last_error = str(exc)
        else:
            last_error = (
                result.stderr or result.stdout
            ).strip() or "Proxmox command failed"
            # `qm config` / `pct config` on an absent guest says:
            #   Configuration file 'nodes/pve/qemu-server/153.conf' does not exist
            # Retrying that 24 times cannot help, and the whole run should not
            # die because one committed stack has not been applied yet.
            if re.search(
                rf"Configuration file .*/{re.escape(vmid)}\.conf' does not exist",
                last_error,
            ):
                raise GuestNotProvisioned(last_error)
        if attempt < attempts:
            time.sleep(delay)
    raise RuntimeError(
        f"Unable to attest SSH host key for {target} through pve after {attempts} attempt(s): {last_error}"
    )


def main() -> int:
    args = parse_args()
    if args.attempts < 1 or args.delay < 0:
        raise ValueError("--attempts must be positive and --delay cannot be negative")

    mapping = json.loads(ATTESTATION_MAP.read_text(encoding="utf-8"))
    guest_inventory = load_inventory(GUEST_INVENTORY)
    pve_inventory = load_inventory(PVE_INVENTORY)
    targets = requested_targets(args, mapping)
    pve = pve_inventory.get("pve")
    if pve is None:
        raise ValueError("pve is missing from ansible/inventory-proxmox.ini")

    root_lines = [
        line
        for line in ROOT_KNOWN_HOSTS.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    output_lines = [
        "# Generated at runtime from the pinned pve trust anchor; do not commit.",
        "# pve root-of-trust entry copied from ansible/ssh_known_hosts.",
        *root_lines,
    ]
    skipped: list[str] = []
    for target in targets:
        entry = guest_inventory.get(target)
        if entry is None or not entry.get("ansible_host"):
            raise ValueError(f"Missing ansible_host inventory entry for {target}")
        try:
            key_type, key = fetch_from_pve(
                pve, mapping[target], target, args.attempts, args.delay
            )
        except GuestNotProvisioned as exc:
            skipped.append(target)
            # Fail-closed: the host simply gets no known_hosts entry, so any
            # attempt to reach it fails host key verification rather than
            # silently trusting whatever answers on its address.
            print(
                f"WARNING: skipping {target}; not provisioned on pve yet ({exc}). "
                "Ansible will refuse to connect to it until it exists.",
                file=sys.stderr,
            )
            continue
        output_lines.extend(
            [
                f"# {target} attested by pve ({mapping[target]['kind']} {mapping[target]['vmid']})",
                f"{entry['ansible_host']} {key_type} {key}",
            ]
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=args.output.parent, delete=False
    ) as handle:
        handle.write("\n".join(output_lines) + "\n")
        temporary = Path(handle.name)
    temporary.chmod(0o600)
    temporary.replace(args.output)
    print(
        f"Generated SSH trust for {len(targets) - len(skipped)} of "
        f"{len(targets)} guest target(s) via pinned pve: {args.output}"
        + (f" (skipped, not provisioned: {', '.join(skipped)})" if skipped else "")
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, KeyError, RuntimeError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1) from exc
