#!/usr/bin/env python3
"""Resolve a target binding from infra-images/catalog.json."""

from __future__ import annotations

import argparse
import json
import shlex
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CATALOG = REPO_ROOT / "infra-images" / "catalog.json"
TARGET_IMAGE_KINDS = {
    "lxc": "lxc-template",
    "vm": "vm-template",
}
IMAGE_REQUIRED_FIELDS = {
    "lxc-template": (
        "proxmox_node",
        "template_datastore_id",
        "template_file_name",
    ),
    "vm-template": (
        "proxmox_node",
        "template_vmid",
        "template_name",
        "packer_dir",
        "packer_vars",
    ),
}
# Universal to every vm-template build, whatever the guest OS.
#
# Was the Ubuntu build's exact variable list, which made this a second,
# narrower source of truth than catalog.json and rejected the windows-11 image
# outright. Two of the old entries were never universal:
#
#   iso_url/iso_checksum  Windows ISOs come from session-tokenized Microsoft
#                         links that expire, so that image supplies a
#                         pre-uploaded Proxmox volume id instead. See
#                         PACKER_BOOT_MEDIA_FORMS below.
#   ssh_timeout           communicator-specific. The Windows build talks WinRM
#                         during the build and only switches to SSH afterwards,
#                         so it sets winrm_timeout.
PACKER_REQUIRED_FIELDS = (
    "iso_storage_pool",
    "vm_storage_pool",
    "bridge",
)

# How the build gets its installation media. An image must supply one COMPLETE
# form; a half-specified one (iso_url with no checksum) is rejected rather than
# silently downloading unverified media.
PACKER_BOOT_MEDIA_FORMS = (
    ("iso_url", "iso_checksum"),  # Packer fetches and verifies it
    ("iso_file",),  # already uploaded; a Proxmox volume id
)
TERRAFORM_TARGET_IMAGE_FIELDS = {
    "01-media-vm": {
        "template_vmid": "template_vmid",
    },
    "01-myapps-vm": {
        "template_vmid": "template_vmid",
    },
    "01-unifi-vm": {
        "template_vmid": "template_vmid",
    },
    "01-backup-lxc": {
        "template_datastore_id": "backup_template_datastore_id",
        "template_file_name": "backup_template_file_name",
    },
    "01-dns-lxc": {
        "template_datastore_id": "dns_template_datastore_id",
        "template_file_name": "dns_template_file_name",
    },
    "01-edge-lxc": {
        "template_datastore_id": "cloudflared_template_datastore_id",
        "template_file_name": "cloudflared_template_file_name",
    },
    "01-observability-lxc": {
        "template_datastore_id": "observability_template_datastore_id",
        "template_file_name": "observability_template_file_name",
    },
    "01-reverse-proxy-lxc": {
        "template_datastore_id": "reverse_proxy_template_datastore_id",
        "template_file_name": "reverse_proxy_template_file_name",
    },
    "01-tailscale-lxc": {
        "template_datastore_id": "tailscale_template_datastore_id",
        "template_file_name": "tailscale_template_file_name",
    },
    "01-torrent-lxc": {
        "template_datastore_id": "qbittorrent_template_datastore_id",
        "template_file_name": "qbittorrent_template_file_name",
    },
    "01-code-lxc": {
        "template_datastore_id": "code_template_datastore_id",
        "template_file_name": "code_template_file_name",
    },
}


class CatalogError(ValueError):
    """A catalog pin cannot be resolved safely."""


def require_mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CatalogError(f"{label} must be a mapping")
    return value


def require_non_empty(mapping: dict[str, Any], key: str, label: str) -> Any:
    if key not in mapping:
        raise CatalogError(f"{label} is missing '{key}'")
    value = mapping[key]
    if value is None or value == "":
        raise CatalogError(f"{label} has empty '{key}'")
    return value


def load_catalog(path: Path) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise CatalogError(f"image catalog not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise CatalogError(f"invalid image catalog JSON: {exc}") from exc

    catalog = require_mapping(raw, "image catalog")
    if catalog.get("schema_version") != 1:
        raise CatalogError("image catalog schema_version must be 1")
    require_mapping(catalog.get("images"), "image catalog images")
    require_mapping(catalog.get("targets"), "image catalog targets")
    return catalog


def validate_image(image_id: str, image: dict[str, Any]) -> None:
    label = f"image '{image_id}'"
    kind = require_non_empty(image, "kind", label)
    if kind not in IMAGE_REQUIRED_FIELDS:
        raise CatalogError(f"{label} has unsupported kind '{kind}'")
    for field in IMAGE_REQUIRED_FIELDS[kind]:
        require_non_empty(image, field, label)

    if kind == "vm-template":
        packer_vars = require_mapping(image["packer_vars"], f"{label} packer_vars")
        for field in PACKER_REQUIRED_FIELDS:
            require_non_empty(packer_vars, field, f"{label} packer_vars")

        # Exactly one complete boot-medium form. Checking for a COMPLETE form
        # rather than for any single key is what stops an image declaring
        # iso_url with no iso_checksum and downloading unverified media.
        satisfied = [
            form
            for form in PACKER_BOOT_MEDIA_FORMS
            if all(packer_vars.get(key) not in (None, "") for key in form)
        ]
        if not satisfied:
            forms = " or ".join("+".join(form) for form in PACKER_BOOT_MEDIA_FORMS)
            raise CatalogError(
                f"{label} packer_vars declares no complete boot medium; supply {forms}"
            )
        packer_dir = REPO_ROOT / str(image["packer_dir"])
        if not packer_dir.is_dir():
            raise CatalogError(
                f"{label} packer_dir does not exist: {image['packer_dir']}"
            )


def resolve_target(catalog: dict[str, Any], target: str) -> dict[str, Any]:
    targets = catalog["targets"]
    images = catalog["images"]
    if target not in targets:
        raise CatalogError(f"target '{target}' is not bound in the image catalog")

    binding = require_mapping(targets[target], f"target '{target}'")
    target_kind = require_non_empty(binding, "kind", f"target '{target}'")
    if target_kind not in TARGET_IMAGE_KINDS:
        raise CatalogError(f"target '{target}' has unsupported kind '{target_kind}'")

    image_id = require_non_empty(binding, "image", f"target '{target}'")
    if image_id not in images:
        raise CatalogError(f"target '{target}' references unknown image '{image_id}'")

    image = require_mapping(images[image_id], f"image '{image_id}'")
    validate_image(image_id, image)
    expected_kind = TARGET_IMAGE_KINDS[target_kind]
    if image["kind"] != expected_kind:
        raise CatalogError(
            f"target '{target}' kind '{target_kind}' requires image kind "
            f"'{expected_kind}', got '{image['kind']}'"
        )

    return {
        "schema_version": catalog["schema_version"],
        "target": target,
        "target_kind": target_kind,
        "image_id": image_id,
        "image": image,
    }


def resolve_image(catalog: dict[str, Any], image_id: str) -> dict[str, Any]:
    images = catalog["images"]
    if image_id not in images:
        raise CatalogError(f"unknown image '{image_id}'")

    image = require_mapping(images[image_id], f"image '{image_id}'")
    validate_image(image_id, image)

    return {
        "schema_version": catalog["schema_version"],
        "image_id": image_id,
        "image": image,
    }


def terraform_env_exports(resolution: dict[str, Any]) -> list[str]:
    target = str(resolution["target"])
    image = require_mapping(resolution["image"], f"target '{target}' image")
    if target not in TERRAFORM_TARGET_IMAGE_FIELDS:
        raise CatalogError(
            f"target '{target}' has no Terraform image variable mapping in the resolver"
        )

    exports = []
    for image_field, terraform_var in TERRAFORM_TARGET_IMAGE_FIELDS[target].items():
        value = require_non_empty(image, image_field, f"target '{target}' image")
        exports.append(f"export TF_VAR_{terraform_var}={shlex.quote(str(value))}")
    return exports


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--target")
    selection.add_argument(
        "--image",
        help="Resolve a catalog image directly for independent image ensure/build operations.",
    )
    parser.add_argument(
        "--format",
        choices=("json", "terraform-shell"),
        default="json",
        help="JSON resolution or shell exports for the target Terraform stack",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        catalog = load_catalog(args.catalog)
        resolution = (
            resolve_target(catalog, args.target)
            if args.target
            else resolve_image(catalog, args.image)
        )
    except CatalogError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if args.format == "terraform-shell":
        if not args.target:
            print("ERROR: terraform-shell output requires --target", file=sys.stderr)
            return 2
        try:
            print("\n".join(terraform_env_exports(resolution)))
        except CatalogError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 2
    else:
        json.dump(resolution, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
