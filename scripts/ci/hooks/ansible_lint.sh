#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
ANSIBLE_LINT_BIN="${ROOT}/.venv/bin/ansible-lint"

if [[ ! -x "${ANSIBLE_LINT_BIN}" ]]; then
  echo "ansible-lint not found at ${ANSIBLE_LINT_BIN}" >&2
  echo "Run: make setup" >&2
  exit 1
fi

cd "${ROOT}/ansible"
exec "${ANSIBLE_LINT_BIN}" --config-file=.ansible-lint
