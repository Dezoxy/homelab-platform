#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/setup/enroll-ssh-host-key.sh <target>
       scripts/setup/enroll-ssh-host-key.sh --verified <fingerprint> <target>

The only supported target is pve. The first form prints the Proxmox SSH key
observed on the network without changing repository trust. Verify its
fingerprint from the Proxmox local console, then pass that console-verified
SHA256 fingerprint to the second form.
EOF
}

verified_fingerprint=""
if [ "${1:-}" = "--verified" ]; then
  if [ "$#" -ne 3 ]; then
    usage
    exit 2
  fi
  verified_fingerprint="$2"
  target="$3"
elif [ "$#" -eq 1 ]; then
  target="$1"
else
  usage
  exit 2
fi

if [ -z "${target}" ]; then
  usage
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "${repo_root}" ]; then
  echo "Run this command inside the homelab repository." >&2
  exit 1
fi

known_hosts="${repo_root}/ansible/ssh_known_hosts"
host_ip="$(
  awk -v target="${target}" '
    $1 == target {
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^ansible_host=/) {
          split($i, value, "=")
          print value[2]
          exit
        }
      }
    }
  ' "${repo_root}/ansible/inventory-proxmox.ini"
)"
if [ -z "${host_ip}" ]; then
  echo "Only the Proxmox root-of-trust host can be enrolled manually: pve" >&2
  echo "Guest host keys are obtained automatically through pinned pve at runtime." >&2
  exit 1
fi

candidate="$(mktemp "${TMPDIR:-/tmp}/ssh-host-key-candidate.XXXXXX")"
updated="$(mktemp "${TMPDIR:-/tmp}/ssh-known-hosts-updated.XXXXXX")"
trap 'rm -f "${candidate}" "${updated}"' EXIT

ssh-keyscan -T 5 -t ed25519 "${host_ip}" 2>/dev/null >"${candidate}" || true
if ! grep -q "^[^#].* ssh-ed25519 " "${candidate}"; then
  echo "No Ed25519 SSH host key received from ${target} (${host_ip})." >&2
  exit 1
fi

echo "Candidate network-observed key for ${target} (${host_ip}); not trusted yet:"
ssh-keygen -lf "${candidate}" -E sha256
fingerprint="$(ssh-keygen -lf "${candidate}" -E sha256 | awk 'NR == 1 { print $2 }')"
echo
echo "Verify from the Proxmox console on ${target}:"
echo "  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256"
echo

if [ -z "${verified_fingerprint}" ]; then
  echo "After the console fingerprint matches, pass that fingerprint explicitly:"
  echo "  scripts/setup/enroll-ssh-host-key.sh --verified '<console-SHA256-fingerprint>' ${target}"
  exit 2
fi

if [ "${fingerprint}" != "${verified_fingerprint}" ]; then
  echo "Refusing to enroll ${target}: network key ${fingerprint} does not match verified key ${verified_fingerprint}." >&2
  exit 1
fi

awk -v host="${host_ip}" -v target="${target}" '
  $1 == host { next }
  $1 == "#" && ($2 == target || $3 == host) { next }
  { print }
' "${known_hosts}" >"${updated}"
{
  printf '# %s %s %s\n' "${target}" "${host_ip}" "${fingerprint}"
  awk '$2 == "ssh-ed25519" { print; exit }' "${candidate}"
} >>"${updated}"
mv "${updated}" "${known_hosts}"

echo "Updated ansible/ssh_known_hosts for ${target}; review and commit the diff."
