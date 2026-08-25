#!/usr/bin/env bash
set -euo pipefail

proxmox_url="${1:-${TF_VAR_proxmox_url:-${PKR_VAR_proxmox_url:-${PROXMOX_API_URL:-}}}}"
if [ -z "${proxmox_url}" ]; then
  echo "A Proxmox API URL is required (argument, TF_VAR_proxmox_url, PKR_VAR_proxmox_url, or PROXMOX_API_URL)." >&2
  exit 1
fi

hostport="${proxmox_url#*://}"
hostport="${hostport%%/*}"
host="${hostport%%:*}"

version_url="${proxmox_url%/}/version"

echo "=== Tailscale Status ==="
tailscale status || true

echo
echo "=== Tailscale IPs ==="
tailscale ip || true

echo
echo "=== IP Route ==="
ip route || true

echo
echo "=== Route To Proxmox Host (${host}) ==="
ip route get "${host}" || true

echo
echo "=== Proxmox API Probe (${version_url}) ==="
curl -k -v \
  --connect-timeout 5 \
  --max-time 10 \
  "${version_url}" || true
