#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Single source of truth. This list was previously duplicated here by hand and
# drifted: 01-unifi-lxc joined targets.sh with the UniFi controller (6d202da)
# and was never copied across, so every scheduled maintenance run silently
# skipped that host -- including the weekly security upgrades.
# shellcheck source=scripts/ci/targets.sh
source "${repo_root}/scripts/ci/targets.sh"

targets=()

add_target() {
  targets+=("$1")
}

if [[ "${EVENT_NAME:-workflow_dispatch}" == "schedule" || "${TARGET_ALL:-false}" == "true" ]]; then
  targets=("${ALL_TARGETS[@]}")
elif [[ -n "${TARGETS:-}" ]]; then
  if [[ "${TARGETS}" == "all" ]]; then
    targets=("${ALL_TARGETS[@]}")
  else
    IFS=',' read -ra raw_targets <<< "${TARGETS}"
    for t in "${raw_targets[@]}"; do
      t="${t// /}"
      [[ -z "$t" ]] && continue
      valid=false
      for known in "${ALL_TARGETS[@]}"; do
        [[ "$t" == "$known" ]] && { valid=true; break; }
      done
      if [[ "$valid" != "true" ]]; then
        echo "Unknown target: '${t}'" >&2
        exit 1
      fi
      add_target "$t"
    done
  fi
else
  # Same convention as deploy.yml: 01-edge-lxc -> TARGET_01_EDGE_LXC. Derived
  # from ALL_TARGETS rather than listed, so a new host cannot be half-added
  # here again. Written as an if rather than `[[ ... ]] && cmd` so a false
  # test cannot trip `set -e`.
  for target in "${ALL_TARGETS[@]}"; do
    var="TARGET_$(printf '%s' "${target}" | tr '[:lower:]-' '[:upper:]_')"
    if [[ "${!var:-false}" == "true" ]]; then
      add_target "${target}"
    fi
  done
fi

if (( ${#targets[@]} == 0 )); then
  echo "Select at least one host, or enable Run on all hosts." >&2
  exit 1
fi

maintenance_limit="$(IFS=:; echo "${targets[*]}")"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'MAINTENANCE_LIMIT=%s\n' "${maintenance_limit}" >> "${GITHUB_ENV}"
else
  printf '%s\n' "${maintenance_limit}"
fi
