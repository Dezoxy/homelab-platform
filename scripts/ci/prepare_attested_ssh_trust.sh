#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
label="${TARGET:-maintenance}"
known_hosts="${ANSIBLE_KNOWN_HOSTS_FILE:-${RUNNER_TEMP:-/tmp}/homelab-attested-known-hosts-${label}}"

if [ -n "${TARGET:-}" ]; then
  selection=(--target "${TARGET}")
elif [ -n "${MAINTENANCE_LIMIT:-}" ]; then
  selection=(--limit "${MAINTENANCE_LIMIT}")
else
  echo "TARGET or MAINTENANCE_LIMIT is required to prepare guest SSH trust." >&2
  exit 1
fi

python3 "${repo_root}/scripts/ci/build_attested_ssh_known_hosts.py" \
  "${selection[@]}" \
  --output "${known_hosts}"

if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'ANSIBLE_KNOWN_HOSTS_FILE=%s\n' "${known_hosts}" >>"${GITHUB_ENV}"
else
  printf 'export ANSIBLE_KNOWN_HOSTS_FILE=%q\n' "${known_hosts}"
fi
