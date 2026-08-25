#!/usr/bin/env bash
set -euo pipefail

inventory="${1:-${ANSIBLE_INVENTORY:-ansible/inventory.ini}}"
limit="${2:-${MAINTENANCE_LIMIT:-}}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
known_hosts="${ANSIBLE_KNOWN_HOSTS_FILE:-${repo_root}/ansible/ssh_known_hosts}"

if [ -z "${limit}" ]; then
  echo "MAINTENANCE_LIMIT (or explicit limit arg) is required." >&2
  exit 1
fi

if [ ! -f "${inventory}" ]; then
  echo "Inventory not found: ${inventory}" >&2
  exit 1
fi

resolve_var() {
  local host="$1"
  local key="$2"
  awk -v h="${host}" -v k="${key}" '
    $1==h {
      for (i=1;i<=NF;i++) {
        if ($i ~ ("^" k "=")) {
          split($i, a, "=")
          print a[2]
          exit
        }
      }
    }
  ' "${inventory}"
}

echo "=== Selected Targets ==="
printf '%s\n' "${limit}"

echo
echo "=== Tailscale Status ==="
tailscale status || true

echo
echo "=== Tailscale IPs ==="
tailscale ip || true

echo
echo "=== IP Route Table ==="
ip route || true

IFS=':' read -r -a targets <<< "${limit}"

for target in "${targets[@]}"; do
  host_ip="$(resolve_var "${target}" ansible_host)"
  ssh_user="$(resolve_var "${target}" ansible_user)"
  if [ -z "${host_ip}" ]; then
    host_ip="${target}"
  fi

  echo
  echo "=== Host: ${target} ==="
  echo "ansible_host=${host_ip}"
  if [ -n "${ssh_user}" ]; then
    echo "ansible_user=${ssh_user}"
  fi

  echo
  echo "--- Route ---"
  ip route get "${host_ip}" || true

  echo
  echo "--- Ping ---"
  ping -c 2 -W 2 "${host_ip}" || true

  echo
  echo "--- TCP 22 Probe ---"
  nc -vz -w 5 "${host_ip}" 22 || true

  echo
  echo "--- Trusted SSH Ed25519 Fingerprint (pinned pve or pve-attested guest) ---"
  ssh-keygen -F "${host_ip}" -f "${known_hosts}" 2>/dev/null |
    awk '$1 !~ /^#/ { print }' |
    ssh-keygen -lf - -E sha256 || true

  echo
  echo "--- Network-observed SSH Ed25519 Fingerprint (diagnostic only, untrusted) ---"
  ssh-keyscan -T 5 -t ed25519 "${host_ip}" 2>/dev/null |
    ssh-keygen -lf - -E sha256 || true
done
