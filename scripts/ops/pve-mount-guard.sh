#!/usr/bin/env bash
set -Eeuo pipefail

# Proxmox pre-start mount guard for host-owned storage.
#
# Problem this solves:
#   Every storage line in /etc/fstab uses `nofail`, so the node boots happily
#   even when a storage volume fails to mount. Without a guard, a guest then
#   starts against a bare-root directory:
#     - writes land on the root filesystem and fill it
#     - /srv/media appears empty, so Plex scans an empty library and REMOVES
#       titles from it, losing watch history, collections and metadata
#   `nofail` at the host level and this fail-closed guard at the guest level
#   are a matched pair. Do not remove one without the other.
#
# Behaviour:
#   Runs on the `pre-start` phase only. Exits non-zero when a required mount is
#   missing or read-only, which makes Proxmox ABORT the guest start.
#   Unknown VMIDs pass through untouched.
#
# /srv/media is mergerfs over /mnt/d8:/mnt/d16:/mnt/d24. mergerfs mounts fine
# with only some branches present, so checking /srv/media alone is NOT enough —
# every branch is verified individually.
#
# Install (on pve):
#   sudo install -m 0755 pve-mount-guard.sh /var/lib/vz/snippets/mount-guard.sh
#   sudo pvesm set local --content vztmpl,iso,backup,import,snippets
#   sudo qm  set 150 --hookscript local:snippets/mount-guard.sh
#   sudo pct set 173 --hookscript local:snippets/mount-guard.sh
#
# Usage (called by Proxmox):
#   mount-guard.sh <vmid> <phase>
#
# Dry run / testing (override the required list, no effect in production):
#   GUARD_REQUIRE_OVERRIDE=/srv/appdata bash mount-guard.sh 150 pre-start
#   GUARD_REQUIRE_OVERRIDE=/nonexistent bash mount-guard.sh 150 pre-start  # must fail

vmid="${1:-}"
phase="${2:-}"

log() { echo "[mount-guard][vmid=${vmid:-?}] $*" >&2; }

# Proxmox calls every phase; only pre-start can veto a start.
[ "${phase}" = "pre-start" ] || exit 0

# Guest -> required host mountpoints. Derived from virtiofs dirid mappings
# (homelab-appdata=/srv/appdata, homelab-media=/srv/media) and LXC mp entries.
case "${vmid}" in
  150)             required="/srv/appdata /srv/media" ;;                 # media-vm
  152|165|174|176) required="/srv/appdata" ;;                            # unifi, tailscale, observability, code
  171)             required="/srv/appdata /srv/media /srv/staging-ssd" ;;# torrent
  173)             required="/srv/appdata /mnt/d16" ;;                   # backup
  *)               exit 0 ;;
esac

# Test hook only; unset in production.
required="${GUARD_REQUIRE_OVERRIDE:-${required}}"

MERGERFS_BRANCHES="/mnt/d8 /mnt/d16 /mnt/d24"

check_mount() {
  local mp="$1" src opts
  if ! src="$(findmnt -nro SOURCE "${mp}" 2>/dev/null)" || [ -z "${src}" ]; then
    log "FAIL: ${mp} is not a mountpoint"
    return 1
  fi
  opts="$(findmnt -nro OPTIONS "${mp}" 2>/dev/null || true)"
  case ",${opts}," in
    *,ro,*)
      log "FAIL: ${mp} is mounted READ-ONLY (${src}) — refusing to start"
      return 1
      ;;
  esac
  log "ok: ${mp} <- ${src}"
  return 0
}

failed=0
for mp in ${required}; do
  check_mount "${mp}" || failed=1
  # mergerfs mounts with partial branches; verify each one.
  if [ "${mp}" = "/srv/media" ]; then
    for branch in ${MERGERFS_BRANCHES}; do
      check_mount "${branch}" || failed=1
    done
  fi
done

if [ "${failed}" -ne 0 ]; then
  log "ABORTING start — host storage is not healthy."
  log "Fix the mount, then start the guest manually. Do NOT bypass this guard:"
  log "  findmnt -no SOURCE,TARGET,FSTYPE /srv/appdata /srv/media /mnt/d8 /mnt/d16 /mnt/d24"
  exit 1
fi

log "all required mounts healthy — allowing start"
exit 0
