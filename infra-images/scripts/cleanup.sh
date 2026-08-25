#!/usr/bin/env bash
set -euo pipefail
log() { echo "[$(date -Is)] $*"; }

log "Cleaning apt caches..."
export DEBIAN_FRONTEND=noninteractive
apt-get autoremove -y
apt-get clean -y
rm -rf /var/lib/apt/lists/*

log "Removing build SSH authorized_keys..."
ssh_user="${PACKER_SSH_USERNAME:-packer}"
if id -u "${ssh_user}" >/dev/null 2>&1; then
  home_dir="$(getent passwd "${ssh_user}" | cut -d: -f6)"
  if [[ -n "${home_dir}" ]]; then
    rm -f "${home_dir}/.ssh/authorized_keys"
  fi
fi
rm -f /root/.ssh/authorized_keys || true

log "Done: cleanup complete."
