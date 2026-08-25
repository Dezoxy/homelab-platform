#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 {terraform|packer|tailscale-outputs}" >&2
}

emit_env() {
  local key="$1"
  local value="$2"
  if [ -z "${GITHUB_ENV:-}" ]; then
    echo "GITHUB_ENV is not set" >&2
    exit 1
  fi
  if [[ "$value" == *$'\n'* ]]; then
    {
      printf '%s<<EOF\n' "$key"
      printf '%s\n' "$value"
      printf 'EOF\n'
    } >>"$GITHUB_ENV"
  else
    printf '%s=%s\n' "$key" "$value" >>"$GITHUB_ENV"
  fi
}

emit_output() {
  local key="$1"
  local value="$2"
  if [ -z "${GITHUB_OUTPUT:-}" ]; then
    echo "GITHUB_OUTPUT is not set" >&2
    exit 1
  fi
  echo "::add-mask::${value}"
  if [[ "$value" == *$'\n'* ]]; then
    {
      printf '%s<<EOF\n' "$key"
      printf '%s\n' "$value"
      printf 'EOF\n'
    } >>"$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
  fi
}

require_vars() {
  local missing=()
  local var
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      missing+=("$var")
    fi
  done
  if ((${#missing[@]} > 0)); then
    printf 'Missing required secret(s): %s\n' "${missing[*]}" >&2
    exit 1
  fi
}

case "${1:-}" in
  terraform)
    require_vars \
      TF_TOKEN_APP_TERRAFORM_IO \
      PROXMOX_API_URL \
      TF_VAR_BOOTSTRAP_PASSWORD \
      PROXMOX_TOKEN_ID \
      PROXMOX_TOKEN_SECRET

    emit_env "TF_TOKEN_app_terraform_io" "$TF_TOKEN_APP_TERRAFORM_IO"
    emit_env "TF_VAR_proxmox_url" "$PROXMOX_API_URL"
    emit_env "TF_VAR_bootstrap_password" "$TF_VAR_BOOTSTRAP_PASSWORD"
    emit_env "TF_VAR_proxmox_token_id" "$PROXMOX_TOKEN_ID"
    emit_env "TF_VAR_proxmox_token_secret" "$PROXMOX_TOKEN_SECRET"
    emit_env "TF_VAR_proxmox_username" "${TF_VAR_PROXMOX_USERNAME:-root@pam}"
    if [ -n "${TF_VAR_PROXMOX_PASSWORD:-}" ]; then
      emit_env "TF_VAR_proxmox_password" "$TF_VAR_PROXMOX_PASSWORD"
    fi
    ;;

  packer)
    require_vars PROXMOX_API_URL PROXMOX_TOKEN_ID PROXMOX_TOKEN_SECRET

    emit_env "PKR_VAR_proxmox_url" "$PROXMOX_API_URL"
    emit_env "PKR_VAR_proxmox_token_id" "$PROXMOX_TOKEN_ID"
    emit_env "PKR_VAR_proxmox_token_secret" "$PROXMOX_TOKEN_SECRET"
    ;;

  tailscale-outputs)
    require_vars TAILSCALE_OAUTH_CLIENT_ID TAILSCALE_OAUTH_SECRET

    emit_output "oauth_client_id" "$TAILSCALE_OAUTH_CLIENT_ID"
    emit_output "oauth_secret" "$TAILSCALE_OAUTH_SECRET"
    ;;

  *)
    usage
    exit 2
    ;;
esac
