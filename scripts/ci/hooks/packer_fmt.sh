#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
PACKER_BIN="${ROOT}/.local/bin/packer"

# shellcheck source=../versions.sh
. "${ROOT}/scripts/ci/versions.sh"

if [[ ! -x "${PACKER_BIN}" ]]; then
  echo "packer not found at ${PACKER_BIN}" >&2
  echo "Run: make install-tools" >&2
  exit 1
fi

installed_ver="$("${PACKER_BIN}" version | sed -n 's/^Packer v//p' | head -1)"
if [[ "${installed_ver}" != "${PACKER_VERSION}" ]]; then
  echo "packer version mismatch: have ${installed_ver}, want ${PACKER_VERSION}" >&2
  echo "Run: make install-tools" >&2
  exit 1
fi

rc=0
while IFS= read -r file; do
  "${PACKER_BIN}" fmt -check "${ROOT}/${file}" || rc=$?
done < <(git -C "${ROOT}" ls-files 'infra-images/packer/**/*.pkr.hcl')
exit "${rc}"
