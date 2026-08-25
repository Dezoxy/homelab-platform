#!/usr/bin/env bash
# Benchmark Ubuntu apt mirrors from a managed guest, to justify apt_mirror_url
# in ansible/group_vars/all.yml rather than guessing at "a closer mirror".
#
# Runs on the guest, not on your workstation: the guest's route to the mirror is
# what a deploy actually pays for, and it can differ sharply from the Mac's.
#
# Usage:
#   scripts/dev/bench_apt_mirrors.sh <host> [ssh-user] [ssh-key]
# Example:
#   scripts/dev/bench_apt_mirrors.sh 192.168.1.4
set -euo pipefail

host="${1:-}"
user="${2:-runner}"
key="${3:-${HOME}/.ssh/runner}"

if [ -z "${host}" ]; then
  echo "Usage: $0 <host> [ssh-user] [ssh-key]" >&2
  exit 2
fi

# Override to compare a different set, e.g. a local apt-cacher-ng instance.
MIRRORS="${MIRRORS:-archive.ubuntu.com de.archive.ubuntu.com hu.archive.ubuntu.com nl.archive.ubuntu.com}"
RUNS="${RUNS:-2}"

# A real index file, so the measurement reflects what apt update actually pulls.
# Resolved on the guest: the fleet is not on a single release (noble vs resolute).
ssh -i "${key}" -o BatchMode=yes -o ConnectTimeout=8 "${user}@${host}" \
  "MIRRORS='${MIRRORS}' RUNS='${RUNS}' bash -s" <<'REMOTE' |
set -u
. /etc/os-release
rel="${VERSION_CODENAME}"
for m in ${MIRRORS}; do
  for run in $(seq 1 "${RUNS}"); do
    out="$(curl -s -o /dev/null --max-time 20 \
      -w '%{http_code} %{speed_download}' \
      "http://${m}/ubuntu/dists/${rel}/main/binary-amd64/Packages.xz" 2>/dev/null || echo "000 0")"
    echo "${m} ${run} ${out}"
  done
done
REMOTE
awk '
  { printf "%-26s run%-3s http=%-4s %8.2f MB/s\n", $1, $2, $3, $4/1048576
    if ($3 == "200") { sum[$1] += $4; n[$1]++ } }
  END {
    print ""
    best = ""; bestv = 0
    for (m in sum) { avg = sum[m]/n[m]; if (avg > bestv) { bestv = avg; best = m } }
    if (best != "") printf "fastest: %s (%.2f MB/s avg)\n", best, bestv/1048576
    else print "no mirror responded successfully"
  }'
