#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }
require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "run as root"; exit 1; }; }

is_ubuntu() { grep -qi ubuntu /etc/os-release; }

require_root

if ! is_ubuntu; then
  echo "This script assumes Ubuntu." >&2
  exit 1
fi

log "Updating package index..."
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
else
  echo "This script assumes Ubuntu (apt-based)." >&2
  exit 1
fi

log "Installing baseline packages..."
apt-get install -y --no-install-recommends \
  qemu-guest-agent \
  cloud-init \
  curl \
  ca-certificates \
  sudo \
  vim-tiny \
  jq \
  net-tools \
  iproute2 \
  cloud-guest-utils \
  openssh-server

log "Enabling qemu-guest-agent..."
systemctl enable --now qemu-guest-agent || true

log "Ensuring SSH is enabled..."
systemctl enable --now ssh || systemctl enable --now sshd || true

log "Cloud-init cleanup for templating..."
cloud-init clean --logs || true

log "Reset machine-id for safe cloning..."
truncate -s 0 /etc/machine-id || true
rm -f /var/lib/dbus/machine-id || true

log "Done: baseline installed."
