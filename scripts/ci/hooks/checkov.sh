#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CHECKOV_BIN="${ROOT}/.venv/bin/checkov"

if [[ ! -x "${CHECKOV_BIN}" ]]; then
  echo "checkov not found at ${CHECKOV_BIN}" >&2
  echo "Run: make setup" >&2
  exit 1
fi

exec "${CHECKOV_BIN}" "$@"
