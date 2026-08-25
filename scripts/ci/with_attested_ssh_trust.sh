#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$2" != "--" ]; then
  echo "Usage: scripts/ci/with_attested_ssh_trust.sh <target|all|host-pattern> -- <command> [args...]" >&2
  exit 2
fi

selection="$1"
shift 2
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
known_hosts="$(mktemp "${TMPDIR:-/tmp}/homelab-attested-known-hosts.XXXXXX")"
trap 'rm -f "${known_hosts}"' EXIT

if [ "${selection}" = "all" ]; then
  target_args=(--all)
else
  target_args=(--limit "${selection}")
fi

python3 "${repo_root}/scripts/ci/build_attested_ssh_known_hosts.py" \
  "${target_args[@]}" \
  --output "${known_hosts}"

ANSIBLE_KNOWN_HOSTS_FILE="${known_hosts}" "$@"
