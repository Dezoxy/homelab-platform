#!/usr/bin/env bash
# Deploy every target in scripts/ci/targets.sh sequentially. Invoked by
# `make deploy-all`; extracted from the Makefile so the result bookkeeping
# below stays readable.
#
# Why this is not a plain `for` loop: the previous inline version ran under
# `bash -eu -o pipefail`, so a failure on target N aborted targets N+1..end with
# no record of them. The fleet was then partially converged, but the run looked
# -- from the exit code and the tail of the log -- like a clean stop on one
# host. Every target is now attempted, each result is recorded, and a summary
# prints at the end. FAIL_FAST=true restores stop-on-first-failure; the summary
# still lists what was never attempted, so partial coverage stays visible
# either way.
#
# ALL_TARGETS is snapshotted when this script starts. A target added to
# targets.sh mid-run is deliberately not picked up -- the summary's "N/M" line
# is what tells you the run predates the edit.
set -u -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 1

# shellcheck source=scripts/ci/targets.sh
source scripts/ci/targets.sh

mode="${MODE:-}"
if [ -z "${mode}" ]; then
  echo "ERROR: MODE is required (config|infra|full)." >&2
  exit 2
fi

fail_fast="${FAIL_FAST:-false}"
skip_updates="${SKIP_UPDATES:-false}"
skip_expand="${SKIP_EXPAND:-false}"
make_bin="${MAKE:-make}"

total="${#ALL_TARGETS[@]}"
if [ "${total}" -eq 0 ]; then
  echo "ERROR: ALL_TARGETS is empty; nothing to deploy." >&2
  exit 2
fi

names=()
results=()
failed=0
stopped=false

for target in "${ALL_TARGETS[@]}"; do
  if [ "${stopped}" = "true" ]; then
    names+=("${target}")
    results+=("SKIPPED")
    continue
  fi

  printf '\n==> Deploying %s (MODE=%s)\n' "${target}" "${mode}"
  if "${make_bin}" --no-print-directory deploy \
    TARGET="${target}" \
    MODE="${mode}" \
    SKIP_UPDATES="${skip_updates}" \
    SKIP_EXPAND="${skip_expand}"; then
    names+=("${target}")
    results+=("OK")
  else
    names+=("${target}")
    results+=("FAILED")
    failed=$((failed + 1))
    printf '\n!!! %s FAILED (MODE=%s)\n' "${target}" "${mode}" >&2
    if [ "${fail_fast}" = "true" ]; then
      stopped=true
    fi
  fi
done

ok_count=0
skipped_count=0
for result in "${results[@]}"; do
  [ "${result}" = "OK" ] && ok_count=$((ok_count + 1))
  [ "${result}" = "SKIPPED" ] && skipped_count=$((skipped_count + 1))
done

printf '\n===== deploy-all summary (MODE=%s) =====\n' "${mode}"
for i in "${!names[@]}"; do
  printf '  %-8s %s\n' "${results[${i}]}" "${names[${i}]}"
done
printf '  %s\n' "-------------------------------------"
printf '  %d/%d ok, %d failed, %d not attempted\n' \
  "${ok_count}" "${total}" "${failed}" "${skipped_count}"

if [ "${failed}" -gt 0 ]; then
  exit 1
fi
