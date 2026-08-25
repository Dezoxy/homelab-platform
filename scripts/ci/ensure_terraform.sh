#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TERRAFORM_VERSION:-}" ]; then
  # shellcheck source=scripts/ci/versions.sh
  source "${SCRIPT_DIR}/versions.sh"
fi

version="${TERRAFORM_VERSION}"

if command -v terraform >/dev/null 2>&1; then
  installed="$(terraform version 2>/dev/null | head -n 1 | awk '{print $2}' | sed 's/^v//')"
  if [ "${installed}" = "${version}" ]; then
    exit 0
  fi
fi

# Only reach for apt when something is genuinely missing. This script runs
# AFTER the "Connect to Tailscale" step, and apt egress does not reliably
# survive the tunnel: an unconditional `apt-get update` here ignored the Azure
# mirror, fell back to archive.ubuntu.com and hung for 38 minutes before the
# job was cancelled. GitHub-hosted runners already ship both tools, so the
# common path never needs the network beyond the release download below.
if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y curl unzip
fi
curl -fsSL -o /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_linux_amd64.zip"
sudo unzip -o /tmp/terraform.zip -d /usr/local/bin
