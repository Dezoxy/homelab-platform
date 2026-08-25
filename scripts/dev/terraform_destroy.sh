#!/usr/bin/env bash
# Run `terraform init` + `terraform destroy` for one Proxmox infra stack.
#
# Used by `make destroy TARGET=<host>`. Expects to be invoked under the secret
# wrapper (scripts/dev/azure_kv_run.sh), which exports the upstream secret names
# (PROXMOX_API_URL, PROXMOX_TOKEN_ID, …). This script remaps them to the
# TF_VAR_* / TF_TOKEN_* names the providers expect — same mapping that
# scripts/dev/terraform_plan.sh does for local plans.
#
# Args:
#   $1 — stack directory name under infra-proxmox/terraform/, e.g. 01-media-vm
#
# Env (provided by the secret wrapper):
#   TF_TOKEN_APP_TERRAFORM_IO   HCP Terraform user/team token
#   PROXMOX_API_URL             https://pve.example.com:8006
#   PROXMOX_TOKEN_ID            terraform@pam!ci
#   PROXMOX_TOKEN_SECRET        the token's secret half
#   TF_VAR_BOOTSTRAP_PASSWORD   bootstrap password baked into new LXCs
#   TF_VAR_PROXMOX_USERNAME     optional — defaults to root@pam
#   TF_VAR_PROXMOX_PASSWORD     optional — only used by some stacks
set -euo pipefail

target="${1:-}"
if [ -z "${target}" ]; then
  echo "usage: $0 <terraform-stack-dirname>" >&2
  exit 2
fi

tf_dir="infra-proxmox/terraform/${target}"
if [ ! -d "${tf_dir}" ]; then
  echo "Terraform directory not found: ${tf_dir}" >&2
  exit 2
fi

required=(TF_TOKEN_APP_TERRAFORM_IO PROXMOX_API_URL PROXMOX_TOKEN_ID PROXMOX_TOKEN_SECRET TF_VAR_BOOTSTRAP_PASSWORD)
missing=()
for v in "${required[@]}"; do
  [ -z "${!v:-}" ] && missing+=("${v}")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing required secrets: ${missing[*]}" >&2
  echo "This script must be invoked through the secret wrapper (scripts/dev/azure_kv_run.sh)." >&2
  exit 1
fi

# shellcheck disable=SC2153 # Key Vault envvar names → Terraform lowercase env names.
export TF_TOKEN_app_terraform_io="${TF_TOKEN_APP_TERRAFORM_IO}"
export TF_VAR_proxmox_url="${PROXMOX_API_URL}"
export TF_VAR_proxmox_token_id="${PROXMOX_TOKEN_ID}"
export TF_VAR_proxmox_token_secret="${PROXMOX_TOKEN_SECRET}"
# shellcheck disable=SC2153
export TF_VAR_bootstrap_password="${TF_VAR_BOOTSTRAP_PASSWORD}"
export TF_VAR_proxmox_username="${TF_VAR_PROXMOX_USERNAME:-root@pam}"
[ -n "${TF_VAR_PROXMOX_PASSWORD:-}" ] && export TF_VAR_proxmox_password="${TF_VAR_PROXMOX_PASSWORD}"


echo ""
echo "════════════════════════════════════════════════════════"
echo " destroy: ${target}"
echo "════════════════════════════════════════════════════════"

(
  cd "${tf_dir}"

  # Drop any cached backend metadata from a previous local init.
  rm -rf .terraform

  # Stacks that use HCP Terraform (the `cloud {}` block in backend.tf) keep
  # their authoritative state remotely. A local terraform.tfstate that
  # pre-dates the migration is stale, but `terraform init` still sees it and
  # asks "migrate this state up?" — which fails under -input=false. Drop it.
  if grep -qE '^[[:space:]]*(cloud|backend)[[:space:]]*[{"]' backend.tf 2>/dev/null; then
    rm -f terraform.tfstate terraform.tfstate.backup
    rm -rf terraform.tfstate.d
  fi

  terraform init -input=false -upgrade=false >/dev/null
  terraform destroy -auto-approve -input=false -no-color
)
