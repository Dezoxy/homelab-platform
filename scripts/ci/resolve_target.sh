#!/usr/bin/env bash
set -euo pipefail

emit_env() {
  local key="$1"
  local value="$2"
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s=%s\n' "${key}" "${value}" >>"${GITHUB_ENV}"
  else
    printf 'export %s=%q\n' "${key}" "${value}"
  fi
}

is_true() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

target="${TARGET:-}"
if [ -z "${target}" ]; then
  echo "TARGET env var is required" >&2
  exit 1
fi

run_terraform="${RUN_TERRAFORM:-}"
run_ansible="${RUN_ANSIBLE:-}"

tf_dir="infra-proxmox/terraform/${target}"
ansible_play="ansible/playbooks/services/${target}.yml"
ansible_limit="${target}"
ansible_bootstrap=false
ansible_run_expand_rootfs=true
ansible_run_system_updates=true
if [[ "${target}" == *-lxc ]]; then
  ansible_bootstrap=true
fi

emit_env "TF_DIR" "${tf_dir}"
emit_env "ANSIBLE_PLAY" "${ansible_play}"
emit_env "ANSIBLE_LIMIT" "${ansible_limit}"
emit_env "ANSIBLE_BOOTSTRAP" "${ansible_bootstrap}"
emit_env "ANSIBLE_RUN_EXPAND_ROOTFS" "${ansible_run_expand_rootfs}"
emit_env "ANSIBLE_RUN_SYSTEM_UPDATES" "${ansible_run_system_updates}"

if is_true "${run_terraform}" && [ ! -d "${tf_dir}" ]; then
  echo "Terraform directory not found for target '${target}': ${tf_dir}" >&2
  exit 1
fi
if is_true "${run_ansible}" && [ ! -f "${ansible_play}" ]; then
  echo "Ansible playbook not found for target '${target}': ${ansible_play}" >&2
  exit 1
fi
