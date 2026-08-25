#!/usr/bin/env python3
"""Validate Proxmox root trust and guest SSH-attestation metadata."""

from __future__ import annotations

import json
import shlex
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GUEST_INVENTORY = REPO_ROOT / "ansible" / "inventory.ini"
PVE_INVENTORY = REPO_ROOT / "ansible" / "inventory-proxmox.ini"
KNOWN_HOSTS = REPO_ROOT / "ansible" / "ssh_known_hosts"
ATTESTATION_MAP = REPO_ROOT / "ansible" / "proxmox_guest_ssh_attestation.json"


def inventory_hosts(inventory: Path) -> dict[str, str]:
    hosts: dict[str, str] = {}
    section = ""
    for raw_line in inventory.read_text(encoding="utf-8").splitlines():
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
        hosts[tokens[0]] = variables.get("ansible_host", tokens[0])
    return hosts


def pinned_hosts() -> dict[str, str]:
    pinned: dict[str, str] = {}
    for raw_line in KNOWN_HOSTS.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        tokens = line.split()
        if len(tokens) != 3 or tokens[1] != "ssh-ed25519":
            raise ValueError(f"Expected plain Ed25519 known_hosts entry: {raw_line}")
        if tokens[0].startswith("|"):
            raise ValueError(
                "Hashed hostnames are not reviewable in ansible/ssh_known_hosts"
            )
        if tokens[0] in pinned:
            raise ValueError(f"Duplicate SSH host key entry for {tokens[0]}")
        pinned[tokens[0]] = tokens[2]
    return pinned


def main() -> int:
    guests = inventory_hosts(GUEST_INVENTORY)
    pve_hosts = inventory_hosts(PVE_INVENTORY)
    attestation = json.loads(ATTESTATION_MAP.read_text(encoding="utf-8"))
    pinned = pinned_hosts()

    pve_ip = pve_hosts.get("pve")
    if pve_ip is None:
        print("Missing pve host in ansible/inventory-proxmox.ini", file=sys.stderr)
        return 1
    if set(pinned) != {pve_ip}:
        print(
            "ansible/ssh_known_hosts must contain exactly the pinned pve root-of-trust key.",
            file=sys.stderr,
        )
        return 1

    missing = sorted(set(guests) - set(attestation))
    extra = sorted(set(attestation) - set(guests))
    invalid = sorted(
        target
        for target, metadata in attestation.items()
        if metadata.get("kind") not in {"lxc", "vm"}
        or not isinstance(metadata.get("vmid"), int)
        or metadata["vmid"] <= 0
    )
    duplicate_vmids = sorted(
        {
            metadata["vmid"]
            for metadata in attestation.values()
            if isinstance(metadata.get("vmid"), int)
            and sum(
                item.get("vmid") == metadata["vmid"] for item in attestation.values()
            )
            > 1
        }
    )
    if missing or extra or invalid or duplicate_vmids:
        for target in missing:
            print(
                f"Missing Proxmox SSH attestation metadata for {target}",
                file=sys.stderr,
            )
        for target in extra:
            print(
                f"Unknown SSH attestation target not in guest inventory: {target}",
                file=sys.stderr,
            )
        for target in invalid:
            print(f"Invalid SSH attestation metadata for {target}", file=sys.stderr)
        for vmid in duplicate_vmids:
            print(f"Duplicate SSH attestation VMID: {vmid}", file=sys.stderr)
        return 1

    print(
        f"Validated pve SSH root trust and Proxmox attestation metadata for {len(guests)} guest hosts."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
