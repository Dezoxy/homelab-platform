#!/usr/bin/env bash
# pre-push hook: run tflint on every Terraform stack directory.
#
# Requires tflint to be installed at .local/bin/tflint.
# Run `make install-tools` once to set it up.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TFLINT_BIN="${ROOT}/.local/bin/tflint"

# Load pinned version
# shellcheck source=../versions.sh
. "${ROOT}/scripts/ci/versions.sh"

# ── version check ─────────────────────────────────────────────────────────────
if [[ ! -x "${TFLINT_BIN}" ]]; then
  echo "tflint not found at ${TFLINT_BIN}" >&2
  echo "Run: make install-tools" >&2
  exit 1
fi

installed_ver="$("${TFLINT_BIN}" --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [[ "${installed_ver}" != "${TFLINT_VERSION}" ]]; then
  echo "tflint version mismatch: have ${installed_ver}, want ${TFLINT_VERSION}" >&2
  echo "Run: make install-tools" >&2
  exit 1
fi

# ── init plugins (idempotent) ─────────────────────────────────────────────────
"${TFLINT_BIN}" --init --config="${ROOT}/.tflint.hcl" >/dev/null

# ── lint every stack directory ─────────────────────────────────────────────────
rc=0
for dir in "${ROOT}"/infra-proxmox/terraform/0*/; do
  # Skip entries that aren't real Terraform directories
  [[ -d "${dir}" ]] || continue
  ls "${dir}"/*.tf &>/dev/null || continue

  echo "tflint: ${dir#"${ROOT}/"}"
  "${TFLINT_BIN}" \
    --chdir="${dir}" \
    --config="${ROOT}/.tflint.hcl" \
    --format=compact \
    --minimum-failure-severity=warning || rc=$?
done
exit "${rc}"
