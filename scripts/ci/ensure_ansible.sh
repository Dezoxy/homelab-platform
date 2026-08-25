#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${ANSIBLE_VERSION:-}" ]; then
  # shellcheck source=scripts/ci/versions.sh
  source "${SCRIPT_DIR}/versions.sh"
fi

version="${ANSIBLE_VERSION}"

venv_dir="/opt/ansible-venv"

ensure_links() {
  sudo ln -sf "${venv_dir}/bin/ansible" /usr/local/bin/ansible
  sudo ln -sf "${venv_dir}/bin/ansible-playbook" /usr/local/bin/ansible-playbook
  sudo ln -sf "${venv_dir}/bin/ansible-galaxy" /usr/local/bin/ansible-galaxy
}

if [ -x "${venv_dir}/bin/python3" ] || [ -x "${venv_dir}/bin/python" ]; then
  venv_python="${venv_dir}/bin/python3"
  if [ ! -x "${venv_python}" ]; then
    venv_python="${venv_dir}/bin/python"
  fi
  installed="$("${venv_python}" -m pip show ansible 2>/dev/null | awk -F': ' '/^Version: /{print $2}' | head -n 1)"
  if [ "${installed}" = "${version}" ]; then
    ensure_links
    exit 0
  fi
fi

# Same reasoning as ensure_terraform.sh: this runs after Tailscale is up, and
# an unconditional apt-get update hangs there. Runners already ship a python3
# with venv/ensurepip, so skip apt unless it is actually absent.
if ! python3 -c 'import venv, ensurepip' >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y python3-venv python3-pip
fi

if [ ! -d "${venv_dir}" ]; then
  sudo python3 -m venv "${venv_dir}"
fi
sudo "${venv_dir}/bin/pip" install --upgrade "ansible==${version}"

ensure_links
