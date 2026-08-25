#!/usr/bin/env bash
set -euo pipefail

proxmox_url="${1:-${TF_VAR_proxmox_url:-${PKR_VAR_proxmox_url:-${PROXMOX_API_URL:-}}}}"
if [ -z "${proxmox_url}" ]; then
  echo "A Proxmox API URL is required (argument, TF_VAR_proxmox_url, PKR_VAR_proxmox_url, or PROXMOX_API_URL)." >&2
  exit 1
fi

retries="${PROXMOX_API_WAIT_RETRIES:-30}"
sleep_seconds="${PROXMOX_API_WAIT_SECONDS:-2}"
version_url="${proxmox_url%/}/version"

for attempt in $(seq 1 "${retries}"); do
  http_code="$(
    curl -k -sS -o /dev/null -w '%{http_code}' \
      --connect-timeout 3 \
      --max-time 5 \
      "${version_url}" 2>/dev/null || true
  )"

  case "${http_code}" in
    200|401|403)
      echo "Proxmox API reachable at ${version_url} (HTTP ${http_code})."
      exit 0
      ;;
  esac

  if [ "${attempt}" -lt "${retries}" ]; then
    echo "Waiting for Proxmox API reachability (${attempt}/${retries})..." >&2
    sleep "${sleep_seconds}"
  fi
done

echo "Proxmox API is not reachable at ${version_url} after ${retries} attempts." >&2
echo "This usually means the GitHub runner does not yet have a working Tailscale/LAN route to ${proxmox_url}." >&2
exit 1
