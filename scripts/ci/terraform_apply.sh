#!/usr/bin/env bash
set -euo pipefail
umask 077

is_true() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

extract_missing_ct_bind_mount_dir() {
  local log_file="$1"
  if [ -f "${log_file}" ]; then
    sed -n "s/.*unable to create CT [0-9]\\+ - directory '\\([^']\\+\\)' does not exist.*/\\1/p" "${log_file}" | head -n 1
  fi
}

target="${TARGET:-}"
if [ -z "${target}" ]; then
  echo "TARGET env var is required" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
# Captured before eval, deliberately. `eval "$(cmd)"` discards cmd's exit
# status -- eval of an empty string succeeds -- so a resolver failure used to
# be invisible here and Terraform simply carried on with whatever defaults the
# stack's variables.tf happened to hold. Measured 2026-08-25: 01-guacamole-lxc
# deployed that way, unpinned, because the target had no mapping in the
# resolver. Its defaults agreed with the catalog, so nothing broke; nothing
# would have told us if they had not.
if ! image_exports="$(
  python3 "${repo_root}/scripts/ci/resolve_image_pin.py" \
    --target "${target}" \
    --format terraform-shell
)"; then
  echo "ERROR: could not resolve the catalog image pin for ${target}; refusing to apply unpinned." >&2
  exit 1
fi
eval "${image_exports}"

tf_dir="${TF_DIR:-}"
if [ -z "${tf_dir}" ]; then
  tf_dir="infra-proxmox/terraform/${target}"
fi
if [ ! -d "${tf_dir}" ]; then
  echo "Terraform directory not found: ${tf_dir}" >&2
  exit 1
fi

runner_temp="${RUNNER_TEMP:-/tmp}"
mkdir -p "${runner_temp}"

force_replace="${FORCE_REPLACE:-false}"

build_tf_args() {
  local _target="$1"
  local _force_replace="$2"

  var_args=()
  replace_args=()

  case "${_target}" in
    01-torrent-lxc)
      # This stack uses Proxmox mount points (host bind mounts).
      # Privileged LXCs are the simplest way to avoid UID/GID mapping surprises.
      var_args+=("-var=qbittorrent_lxc_unprivileged=false")
      ;;
    01-observability-lxc)
      var_args+=("-var=observability_lxc_unprivileged=false")
      ;;
    01-backup-lxc)
      var_args+=("-var=backup_lxc_unprivileged=false")
      ;;
    01-tailscale-lxc)
      # Tailscale subnet routing in LXC is simplest in privileged mode.
      var_args+=("-var=tailscale_lxc_unprivileged=false")
      ;;
  esac

  if [[ "${_target}" == *-lxc ]] && is_true "${_force_replace}"; then
    # Every current LXC stack manages its container through the shared module.
    replace_args+=("-replace=module.lxc.proxmox_virtual_environment_container.this")
  fi
  if [ "${_target}" = "01-media-vm" ] && is_true "${_force_replace}"; then
    replace_args+=("-replace=module.vm.proxmox_virtual_environment_vm.this")
  fi
}

primary_vm_resource_addr() {
  case "${target}" in
    01-media-vm)
      echo "module.vm.proxmox_virtual_environment_vm.this"
      ;;
  esac
}

require_media_rebuild_manifest() {
  local manifest="${MEDIA_REBUILD_MANIFEST_FILE:-}"
  if ! is_true "${MEDIA_REBUILD_APPROVED:-false}" \
    || [ -z "${manifest}" ] \
    || [[ "${manifest}" != /* ]] \
    || [ ! -f "${manifest}" ]; then
    cat >&2 <<'EOF'
Refusing replacement of 01-media-vm.

Its application state is intentionally stored on the VM root disk. A VM
replacement requires a stopped-state mirror into /srv/appdata and a verified
offsite appdata snapshot. Use:

  make rebuild-media
EOF
    exit 1
  fi

  python3 - "${manifest}" <<'PY'
import json
import sys
import time

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    manifest = json.load(source)

if manifest.get("target") != "01-media-vm":
    raise SystemExit("Media rebuild manifest does not target 01-media-vm.")
if manifest.get("status") != "verified" or manifest.get("services_quiesced") is not True:
    raise SystemExit("Media rebuild manifest is not a verified stopped-state snapshot.")

prepared_epoch = int(manifest.get("prepared_epoch", 0))
age_seconds = int(time.time()) - prepared_epoch
if age_seconds < 0 or age_seconds > 21600:
    raise SystemExit("Media rebuild manifest is expired; create a new stopped-state snapshot.")
PY
}

guard_media_vm_replacement() {
  local vm_addr plan_file
  local replacement_required=false

  if [ "${target}" != "01-media-vm" ]; then
    return 0
  fi

  if is_true "${force_replace}"; then
    replacement_required=true
  else
    vm_addr="$(primary_vm_resource_addr)"
    plan_file="${runner_temp}/media-vm-replacement-guard.tfplan"
    rm -f "${plan_file}"
    terraform init -input=false >/dev/null
    if ! terraform plan -input=false -lock=false -no-color -out="${plan_file}" \
      ${var_args[@]+"${var_args[@]}"} ${replace_args[@]+"${replace_args[@]}"} >/dev/null; then
      rm -f "${plan_file}"
      echo "Unable to generate media VM replacement safety plan; refusing apply." >&2
      exit 1
    fi
    if terraform show -json "${plan_file}" |
      python3 -c '
import json
import sys

address = sys.argv[1]
plan = json.load(sys.stdin)
for change in plan.get("resource_changes", []):
    if change.get("address") == address:
        actions = change.get("change", {}).get("actions", [])
        raise SystemExit(0 if "delete" in actions else 1)
raise SystemExit(1)
' "${vm_addr}"; then
      replacement_required=true
    fi
    rm -f "${plan_file}"
  fi

  if is_true "${replacement_required}"; then
    require_media_rebuild_manifest
  fi
}

apply_with_import_retries() {
  local log_file="$1"
  local allow_import_failure="$2"
  shift 2

  terraform init -input=false

  # A failed VM create (including Proxmox task status races) can taint the VM in Terraform state.
  # That would force a destroy/create replacement on the next run, which is almost never desired.
  vm_resource_addr="$(primary_vm_resource_addr)"
  if [ -n "${vm_resource_addr:-}" ]; then
    terraform untaint -allow-missing "${vm_resource_addr}" >/dev/null 2>&1 || true
  fi

  max_import_retries=5
  for i in $(seq 1 "${max_import_retries}"); do
    set +e
    terraform apply -auto-approve -input=false -no-color "$@" 2>&1 | tee "${log_file}"
    apply_rc=${PIPESTATUS[0]}
    set -e
    if [ "${apply_rc}" -eq 0 ]; then
      return 0
    fi

    mapping_pci_id="$(sed -n "s/.*create hardware mapping failed: pci ID '\\([^']\\+\\)' already defined.*/\\1/p" "${log_file}" | head -n 1)"
    mapping_pci_addr="$(sed -n "s/.*with \\(proxmox_virtual_environment_hardware_mapping_pci\\.[^,]*\\).*/\\1/p" "${log_file}" | head -n 1)"
    if [ -n "${mapping_pci_id}" ] && [ -n "${mapping_pci_addr}" ]; then
      echo "Hardware mapping already exists in Proxmox; importing '${mapping_pci_id}' into state (${mapping_pci_addr}) and retrying (${i}/${max_import_retries})..."
      if [ "${allow_import_failure}" = "true" ]; then
        terraform import -input=false "${mapping_pci_addr}" "${mapping_pci_id}" || true
      else
        terraform import -input=false "${mapping_pci_addr}" "${mapping_pci_id}"
      fi
      continue
    fi

    mapping_dir_name="$(sed -n -E "s/.*create hardware mapping failed: (directory mapping|dir ID) '([^']+)' already defined.*/\\2/p" "${log_file}" | head -n 1)"
    mapping_dir_addr="$(sed -n "s/.*with \\(proxmox_virtual_environment_hardware_mapping_dir\\.[^,]*\\).*/\\1/p" "${log_file}" | head -n 1)"
    if [ -n "${mapping_dir_name}" ] && [ -n "${mapping_dir_addr}" ]; then
      echo "Directory mapping already exists in Proxmox; importing '${mapping_dir_name}' into state (${mapping_dir_addr}) and retrying (${i}/${max_import_retries})..."
      if [ "${allow_import_failure}" = "true" ]; then
        terraform import -input=false "${mapping_dir_addr}" "${mapping_dir_name}" || true
      else
        terraform import -input=false "${mapping_dir_addr}" "${mapping_dir_name}"
      fi
      continue
    fi

    # Work around a Proxmox task exitstatus race: the VM can start successfully, but the API briefly reports
    # an empty/unknown exit status for the qmstart task, which makes the provider fail the apply.
    vm_start_vmid="$(sed -n -E 's/.*error waiting for VM start: task "UPID:[^:]+:[^:]+:[^:]+:[^:]+:qmstart:([0-9]+):.*/\1/p' "${log_file}" | head -n 1)"
    vm_start_addr="$(sed -n -E 's/.*with ((module[.][^,]+[.])?proxmox_virtual_environment_vm[.][^,]+).*/\1/p' "${log_file}" | head -n 1)"
    if [ -n "${vm_start_vmid}" ] && [ -n "${vm_start_addr}" ] && grep -q 'failed to complete with exit code: unexpected status' "${log_file}"; then
      echo "VM start reported an unexpected task exit status; importing VM '${vm_start_vmid}' into state (${vm_start_addr}) and retrying (${i}/${max_import_retries})..."
      terraform import -input=false "${vm_start_addr}" "${vm_start_vmid}" || true
      terraform untaint -allow-missing "${vm_start_addr}" >/dev/null 2>&1 || true
      # Proxmox can report the qmstart task before its follow-up metadata fully settles.
      # Give the API a short window to catch up so the next apply can see the VM cleanly.
      sleep 15
      continue
    fi

    return "${apply_rc}"
  done

  echo "Exceeded ${max_import_retries} import retries; see ${log_file}" >&2
  return 1
}

cd "${tf_dir}"

# If env vars are missing, try to read them from terraform.tfvars in the target directory.
# This lets local deploys use tfvars as the single source of truth instead of .env.
_read_tfvar() {
  local key="$1" file="terraform.tfvars"
  # Use -E (extended regex) for macOS BSD sed compatibility — \? is a GNU
  # extension and silently matches nothing on BSD sed, swallowing the value.
  [ -f "${file}" ] && sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*[\"']?([^\"'#]*)[\"']?[[:space:]]*/\1/p" "${file}" | head -n1 | tr -d '[:space:]'
}

# Variable resolution order, highest precedence first:
#   1. TF_VAR_* env var (set by CI's export_runtime_env.sh, or by the
#      caller for local invocations)
#   2. The secret store's uppercase name (set by the secret wrapper
#      scripts/dev/azure_kv_run.sh — used by local `make deploy MODE=infra`)
#   3. terraform.tfvars value (legacy local-only path)
: "${TF_VAR_proxmox_url:=${PROXMOX_API_URL:-$(_read_tfvar proxmox_url)}}"
: "${TF_VAR_proxmox_token_id:=${PROXMOX_TOKEN_ID:-$(_read_tfvar proxmox_token_id)}}"
: "${TF_VAR_proxmox_token_secret:=${PROXMOX_TOKEN_SECRET:-$(_read_tfvar proxmox_token_secret)}}"
: "${TF_VAR_proxmox_password:=${TF_VAR_PROXMOX_PASSWORD:-$(_read_tfvar proxmox_password)}}"
: "${TF_VAR_proxmox_username:=${TF_VAR_PROXMOX_USERNAME:-root@pam}}"
: "${TF_VAR_bootstrap_password:=${TF_VAR_BOOTSTRAP_PASSWORD:-}}"
: "${TF_TOKEN_app_terraform_io:=${TF_TOKEN_APP_TERRAFORM_IO:-}}"
export TF_VAR_proxmox_url TF_VAR_proxmox_token_id TF_VAR_proxmox_token_secret TF_VAR_proxmox_password
export TF_VAR_proxmox_username TF_VAR_bootstrap_password
export TF_TOKEN_app_terraform_io

if [ -z "${TF_VAR_proxmox_url:-}" ] || [ -z "${TF_VAR_proxmox_token_id:-}" ] || [ -z "${TF_VAR_proxmox_token_secret:-}" ]; then
  echo "Missing Proxmox credentials. Set TF_VAR_proxmox_url, TF_VAR_proxmox_token_id, TF_VAR_proxmox_token_secret" >&2
  echo "via env vars, .env file, or terraform.tfvars in ${tf_dir}." >&2
  exit 1
fi

build_tf_args "${target}" "${force_replace}"
guard_media_vm_replacement

token_log="${runner_temp}/terraform-apply.log"
set +e
apply_with_import_retries "${token_log}" "true" ${var_args[@]+"${var_args[@]}"} ${replace_args[@]+"${replace_args[@]}"}
token_rc=$?
set -e
if [ "${token_rc}" -eq 0 ]; then
  exit 0
fi

if [ -f "${token_log}" ] && grep -Eqi 'connect: network is unreachable|no route to host|i/o timeout|connection refused|context deadline exceeded|operation timed out' "${token_log}"; then
  echo "Terraform could not reach the Proxmox API at ${TF_VAR_proxmox_url}." >&2
  echo "This is a runner/Tailscale connectivity failure, not a Proxmox authentication failure." >&2
  echo "See ${token_log} for details." >&2
  exit "${token_rc}"
fi

need_root_auth=false
if [ -f "${token_log}" ] && grep -Eq 'received an HTTP 403 response|HTTP 403 response|Permission check failed|Only root can pass arbitrary filesystem paths' "${token_log}"; then
  need_root_auth=true
fi
if [[ "${target}" == *-lxc ]]; then
  need_root_auth=true
fi

if [ "${need_root_auth}" != "true" ]; then
  missing_dir="$(extract_missing_ct_bind_mount_dir "${token_log}")"
  if [ -n "${missing_dir:-}" ]; then
    echo "Terraform apply failed because a Proxmox host bind-mount source directory is missing: ${missing_dir}" >&2
    echo "Create it on the Proxmox node, then rerun deploy. Example:" >&2
    echo "  sudo install -d -m 0755 '${missing_dir}'" >&2
  fi
  echo "Terraform apply failed without a Proxmox permission/root@pam indicator." >&2
  echo "See ${token_log} for details." >&2
  exit "${token_rc}"
fi

if [ -z "${TF_VAR_proxmox_password:-}" ]; then
  echo "Terraform needs root@pam fallback, but the root password secret is not set." >&2
  echo "Set TF_VAR_PROXMOX_PASSWORD (preferred) or PROXMOX_ROOT_PASSWORD in GitHub Secrets." >&2
  exit 1
fi

root_log="${runner_temp}/terraform-apply-root.log"
build_tf_args "${target}" "${force_replace}"
set +e
apply_with_import_retries "${root_log}" "false" ${var_args[@]+"${var_args[@]}"} ${replace_args[@]+"${replace_args[@]}"}
root_rc=$?
set -e
if [ "${root_rc}" -ne 0 ]; then
  missing_dir="$(extract_missing_ct_bind_mount_dir "${root_log}")"
  if [ -n "${missing_dir:-}" ]; then
    echo "Terraform apply failed because a Proxmox host bind-mount source directory is missing: ${missing_dir}" >&2
    echo "Create it on the Proxmox node, then rerun deploy. Example:" >&2
    echo "  sudo install -d -m 0755 '${missing_dir}'" >&2
  fi
  exit "${root_rc}"
fi
