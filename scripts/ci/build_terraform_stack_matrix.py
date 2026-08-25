#!/usr/bin/env python3
"""Emit a GitHub Actions matrix for managed Terraform stacks."""

from __future__ import annotations

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TERRAFORM_ROOT = REPO_ROOT / "infra-proxmox" / "terraform"


def main() -> None:
    stacks = sorted(
        path
        for path in TERRAFORM_ROOT.iterdir()
        if path.is_dir() and (path / "backend.tf").is_file()
    )
    if not stacks:
        raise SystemExit(
            f"No Terraform stacks with backend.tf found in {TERRAFORM_ROOT}"
        )

    include = [
        {
            "name": stack.name,
            "dir": stack.relative_to(REPO_ROOT).as_posix(),
        }
        for stack in stacks
    ]
    print(json.dumps({"include": include}, separators=(",", ":")))


if __name__ == "__main__":
    main()
