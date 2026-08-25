#!/usr/bin/env bash
set -euo pipefail

target="${TARGET:-${1:-}}"
image_id="${IMAGE_ID:-}"
if { [ -z "${target}" ] && [ -z "${image_id}" ]; } || { [ -n "${target}" ] && [ -n "${image_id}" ]; }; then
  echo "Set exactly one of TARGET/target argument or IMAGE_ID" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
selection="${target:-${image_id}}"

prepare_packer_ssh_key() {
  if [ -n "${PKR_VAR_ssh_public_key:-}" ] && [ -n "${PKR_VAR_ssh_private_key_file:-}" ]; then
    return 0
  fi

  key_dir="${PACKER_SSH_KEY_DIR:-${RUNNER_TEMP:-/tmp}/homelab-packer-${selection}}"
  key_path="${key_dir}/packer"
  mkdir -p "${key_dir}"
  if [ ! -f "${key_path}" ]; then
    ssh-keygen -q -t ed25519 -f "${key_path}" -N "" -C "homelab-packer-${selection}"
  fi

  export PKR_VAR_ssh_public_key
  export PKR_VAR_ssh_private_key_file="${key_path}"
  PKR_VAR_ssh_public_key="$(cat "${key_path}.pub")"
}

# The key is used only when a VM template is missing and the Ansible role runs
# Packer. Creating it here keeps the pre-apply ensure step self-contained.
prepare_packer_ssh_key

ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-${repo_root}/ansible/ansible.cfg}" \
  ansible-playbook \
  -i "${repo_root}/ansible/inventory-proxmox.ini" \
  "${repo_root}/ansible/playbooks/proxmox/ensure-target-image.yml" \
  -e "proxmox_image_target=${target}" \
  -e "proxmox_image_id=${image_id}"
