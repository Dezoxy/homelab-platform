#!/usr/bin/env bash
set -Eeuo pipefail

# Repair Proxmox LXC thin-volume warning:
#
#   WARNING: Thin volume <vg>/vm-<ctid>-disk-<n> maps X GiB while the size is only Y GiB
#
# Safe repair method:
#   1. stop CT
#   2. create vzdump backup
#   3. verify backup archive is readable
#   4. destroy old CT
#   5. restore SAME CTID from backup
#   6. start CT
#   7. verify CT boots and filesystem is readable
#   8. verify LVM warning disappeared
#   9. optionally remove backup
#
# Usage:
#   sudo bash repair-shrunk-lxc-thin.sh 165 171 172 174
#
# Dry run:
#   sudo DRY_RUN=yes bash repair-shrunk-lxc-thin.sh 165
#
# Safer first real run:
#   sudo REMOVE_BACKUP=no bash repair-shrunk-lxc-thin.sh 165
#
# Optional environment variables:
#   BACKUP_STORAGE=local
#   BACKUP_DIR=/var/lib/vz/dump
#   RESTORE_STORAGE=local-lvm
#   REMOVE_BACKUP=no
#   DRY_RUN=no
#   VERIFY_CMD="systemctl --failed"
#
# Example:
#   sudo DRY_RUN=yes ./repair-shrunk-lxc-thin.sh 165
#
# Example real run:
#   sudo BACKUP_STORAGE=local RESTORE_STORAGE=local-lvm REMOVE_BACKUP=no ./repair-shrunk-lxc-thin.sh 165
#
# Example with custom verification:
#   sudo VERIFY_CMD="systemctl --failed" REMOVE_BACKUP=no ./repair-shrunk-lxc-thin.sh 165

BACKUP_STORAGE="${BACKUP_STORAGE:-local}"
BACKUP_DIR="${BACKUP_DIR:-/var/lib/vz/dump}"
RESTORE_STORAGE="${RESTORE_STORAGE:-local-lvm}"

# Safer default: keep backup unless explicitly requested.
REMOVE_BACKUP="${REMOVE_BACKUP:-no}"

# Dry run default: no.
DRY_RUN="${DRY_RUN:-no}"

# Optional command executed inside the restored CT after boot.
VERIFY_CMD="${VERIFY_CMD:-}"

LOG_DIR="${LOG_DIR:-/root/lxc-thin-repair-logs}"
mkdir -p "$LOG_DIR"

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  echo "[$(timestamp)] $*"
}

die() {
  echo "[$(timestamp)] ERROR: $*" >&2
  exit 1
}

is_dry_run() {
  [[ "$DRY_RUN" == "yes" ]]
}

run_or_dry() {
  if is_dry_run; then
    log "[DRY-RUN] Would run: $*"
  else
    "$@"
  fi
}

on_error() {
  local exit_code=$?
  local line_no="${1:-unknown}"

  echo >&2
  echo "[$(timestamp)] ERROR: Script failed at line ${line_no} with exit code ${exit_code}" >&2
  echo "[$(timestamp)] ERROR: If the failure happened after backup creation, check logs in: ${LOG_DIR}" >&2
  echo >&2

  exit "$exit_code"
}

trap 'on_error $LINENO' ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root, for example: sudo bash $0 165"
}

require_commands() {
  local cmds=(
    pct
    vzdump
    pvesm
    lvs
    zstdcat
    tar
    awk
    grep
    sort
    tail
    find
    date
  )

  for cmd in "${cmds[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
  done
}

validate_yes_no() {
  local name="$1"
  local value="$2"

  [[ "$value" == "yes" || "$value" == "no" ]] \
    || die "$name must be either yes or no, got: $value"
}

validate_settings() {
  validate_yes_no "REMOVE_BACKUP" "$REMOVE_BACKUP"
  validate_yes_no "DRY_RUN" "$DRY_RUN"

  if is_dry_run && [[ "$REMOVE_BACKUP" == "yes" ]]; then
    log "DRY_RUN=yes is active, so REMOVE_BACKUP=yes will only be simulated"
  fi
}

validate_ctid() {
  local ctid="$1"

  [[ "$ctid" =~ ^[0-9]+$ ]] || die "Invalid CTID: $ctid"
}

check_ct_exists() {
  local ctid="$1"

  pct config "$ctid" >/dev/null 2>&1 || die "CT $ctid does not exist"
}

check_backup_dir() {
  [[ -d "$BACKUP_DIR" ]] || die "Backup directory does not exist: $BACKUP_DIR"

  if is_dry_run; then
    log "[DRY-RUN] Skipping writable check for backup directory: $BACKUP_DIR"
  else
    [[ -w "$BACKUP_DIR" ]] || die "Backup directory is not writable: $BACKUP_DIR"
  fi
}

check_storage_exists() {
  local storage="$1"

  pvesm status | awk 'NR > 1 {print $1}' | grep -qx "$storage" \
    || die "Storage does not exist or is unavailable: $storage"
}

preflight_storage_checks() {
  log "Checking backup storage exists: $BACKUP_STORAGE"
  check_storage_exists "$BACKUP_STORAGE"

  log "Checking restore storage exists: $RESTORE_STORAGE"
  check_storage_exists "$RESTORE_STORAGE"

  log "Checking backup directory: $BACKUP_DIR"
  check_backup_dir
}

get_latest_backup_file() {
  local ctid="$1"

  find "$BACKUP_DIR" -maxdepth 1 -type f \
    -name "vzdump-lxc-${ctid}-*.tar.zst" \
    -printf "%T@ %p\n" \
    | sort -nr \
    | awk 'NR==1 {print $2}'
}

verify_backup_archive() {
  local backup_file="$1"

  [[ -f "$backup_file" ]] || die "Backup file not found: $backup_file"
  [[ -s "$backup_file" ]] || die "Backup file is empty: $backup_file"

  log "Verifying backup archive is readable: $backup_file"

  zstdcat "$backup_file" | tar -tf - >/dev/null

  log "Backup archive verification OK"
}

wait_for_ct_stopped() {
  local ctid="$1"
  local timeout_seconds="${2:-60}"
  local waited=0

  while (( waited < timeout_seconds )); do
    if pct status "$ctid" | grep -q "status: stopped"; then
      return 0
    fi

    sleep 2
    waited=$((waited + 2))
  done

  return 1
}

wait_for_ct_running() {
  local ctid="$1"
  local timeout_seconds="${2:-60}"
  local waited=0

  while (( waited < timeout_seconds )); do
    if pct status "$ctid" | grep -q "status: running"; then
      return 0
    fi

    sleep 2
    waited=$((waited + 2))
  done

  return 1
}

stop_ct_safely() {
  local ctid="$1"

  log "Stopping CT $ctid"

  if pct status "$ctid" | grep -q "status: stopped"; then
    log "CT $ctid is already stopped"
    return 0
  fi

  if is_dry_run; then
    log "[DRY-RUN] Would stop CT $ctid"
    return 0
  fi

  pct stop "$ctid"

  wait_for_ct_stopped "$ctid" 60 || die "CT $ctid did not stop within timeout"
}

has_lvm_warning_for_ct() {
  local ctid="$1"
  local output

  output="$(lvs -a -o lv_name,vg_name,lv_size,data_percent,metadata_percent,origin,pool_lv 2>&1 || true)"

  grep -E "WARNING: Thin volume .*/vm-${ctid}-disk-[0-9]+ maps" <<< "$output" >/dev/null
}

show_lvm_warning_for_ct() {
  local ctid="$1"

  lvs -a -o lv_name,vg_name,lv_size,data_percent,metadata_percent,origin,pool_lv 2>&1 \
    | grep -E "WARNING: Thin volume .*/vm-${ctid}-disk-[0-9]+ maps|vm-${ctid}-disk" || true
}

verify_ct_after_restore() {
  local ctid="$1"

  if is_dry_run; then
    log "[DRY-RUN] Would verify restored CT $ctid:"
    log "[DRY-RUN]   pct status $ctid"
    log "[DRY-RUN]   wait until running"
    log "[DRY-RUN]   pct exec $ctid -- df -h"

    if [[ -n "$VERIFY_CMD" ]]; then
      log "[DRY-RUN]   pct exec $ctid -- bash -lc '$VERIFY_CMD'"
    fi

    return 0
  fi

  log "Checking CT $ctid status"
  pct status "$ctid"

  wait_for_ct_running "$ctid" 60 || die "CT $ctid did not reach running state"

  log "Running basic filesystem check inside CT $ctid"
  pct exec "$ctid" -- df -h >/dev/null

  if [[ -n "$VERIFY_CMD" ]]; then
    log "Running custom verification command inside CT $ctid:"
    log "$VERIFY_CMD"

    pct exec "$ctid" -- bash -lc "$VERIFY_CMD"
  fi

  log "CT $ctid restore verification OK"
}

backup_ct() {
  local ctid="$1"
  local logfile="$2"

  if is_dry_run; then
    log "[DRY-RUN] Would create vzdump backup for CT $ctid" >&2
    log "[DRY-RUN] Would run: vzdump $ctid --storage $BACKUP_STORAGE --mode stop --compress zstd" >&2
    log "[DRY-RUN] Would detect newest backup in: $BACKUP_DIR" >&2
    log "[DRY-RUN] Would verify backup archive with: zstdcat <backup> | tar -tf -" >&2
    printf '%s\n' "/dry-run/vzdump-lxc-${ctid}-YYYY_MM_DD-HH_MM_SS.tar.zst"
    return 0
  fi

  log "Creating vzdump backup for CT $ctid" >&2

  vzdump "$ctid" \
    --storage "$BACKUP_STORAGE" \
    --mode stop \
    --compress zstd \
    2>&1 | tee -a "$logfile" >&2

  local backup_file
  backup_file="$(get_latest_backup_file "$ctid")"

  [[ -n "$backup_file" ]] || die "Could not find backup file for CT $ctid in $BACKUP_DIR"

  log "Detected backup file: $backup_file" >&2

  verify_backup_archive "$backup_file" >&2

  printf '%s\n' "$backup_file"
}

repair_ct() {
  local ctid="$1"
  local logfile
  logfile="$LOG_DIR/repair-ct-${ctid}-$(date +%Y%m%d-%H%M%S).log"

  validate_ctid "$ctid"
  check_ct_exists "$ctid"

  log "============================================================"
  log "Starting repair for CT $ctid"
  log "Log file: $logfile"
  log "Backup storage: $BACKUP_STORAGE"
  log "Backup directory: $BACKUP_DIR"
  log "Restore storage: $RESTORE_STORAGE"
  log "Remove backup after success: $REMOVE_BACKUP"
  log "Dry run: $DRY_RUN"
  log "Custom verify command: ${VERIFY_CMD:-none}"
  log "============================================================"

  {
    echo "===== Repair started: $(timestamp) ====="
    echo "CTID: $ctid"
    echo "BACKUP_STORAGE: $BACKUP_STORAGE"
    echo "BACKUP_DIR: $BACKUP_DIR"
    echo "RESTORE_STORAGE: $RESTORE_STORAGE"
    echo "REMOVE_BACKUP: $REMOVE_BACKUP"
    echo "DRY_RUN: $DRY_RUN"
    echo "VERIFY_CMD: ${VERIFY_CMD:-none}"
    echo
  } >> "$logfile"

  log "Current CT config for $ctid:"
  pct config "$ctid" | tee -a "$logfile"

  log "Current LVM warning/volume view for CT $ctid:"
  show_lvm_warning_for_ct "$ctid" | tee -a "$logfile"

  if ! has_lvm_warning_for_ct "$ctid"; then
    log "No matching LVM thin warning found for CT $ctid before repair."
    log "Skipping CT $ctid to avoid unnecessary destructive operation."
    return 0
  fi

  if is_dry_run; then
    log "[DRY-RUN] CT $ctid has a matching LVM warning and would be repaired."
  fi

  stop_ct_safely "$ctid"

  local backup_file
  backup_file="$(backup_ct "$ctid" "$logfile")"

  if is_dry_run; then
    log "[DRY-RUN] Backup creation and verification would be completed before destroy/restore phase for CT $ctid."
  else
    log "Backup verified successfully. Proceeding with destroy/restore phase for CT $ctid."
  fi

  if is_dry_run; then
    log "[DRY-RUN] Would destroy old CT $ctid"
  else
    log "Destroying old CT $ctid"
    pct destroy "$ctid"
  fi

  if is_dry_run; then
    log "[DRY-RUN] Would restore CT $ctid to same ID on storage $RESTORE_STORAGE from:"
    log "[DRY-RUN]   $backup_file"
  else
    log "Restoring CT $ctid to same ID on storage $RESTORE_STORAGE"
    pct restore "$ctid" "$backup_file" --storage "$RESTORE_STORAGE" 2>&1 | tee -a "$logfile"
  fi

  if is_dry_run; then
    log "[DRY-RUN] Would start restored CT $ctid"
  else
    log "Starting restored CT $ctid"
    pct start "$ctid"
  fi

  verify_ct_after_restore "$ctid"

  if is_dry_run; then
    log "[DRY-RUN] Would check LVM warning after restore for CT $ctid"
    log "[DRY-RUN] Would fail if warning still matched:"
    log "[DRY-RUN]   WARNING: Thin volume .*/vm-${ctid}-disk-[0-9]+ maps"
  else
    log "Checking LVM warning after restore for CT $ctid"
    show_lvm_warning_for_ct "$ctid" | tee -a "$logfile"

    if has_lvm_warning_for_ct "$ctid"; then
      die "LVM warning still exists for CT $ctid after restore. Backup was kept: $backup_file"
    fi

    log "No matching LVM thin warning found for CT $ctid after restore"
  fi

  if [[ "$REMOVE_BACKUP" == "yes" ]]; then
    if is_dry_run; then
      log "[DRY-RUN] Would remove backup file: $backup_file"
    else
      log "Removing backup file: $backup_file"
      rm -f -- "$backup_file"
    fi
  else
    log "Keeping backup file: $backup_file"
  fi

  if is_dry_run; then
    log "[DRY-RUN] Repair simulation completed successfully for CT $ctid"
  else
    log "Repair completed successfully for CT $ctid"
  fi

  {
    echo
    if is_dry_run; then
      echo "===== Dry-run completed successfully: $(timestamp) ====="
    else
      echo "===== Repair completed successfully: $(timestamp) ====="
    fi
  } >> "$logfile"
}

main() {
  require_root
  require_commands
  validate_settings

  [[ "$#" -ge 1 ]] || die "Usage: sudo bash $0 <CTID> [CTID...]"

  if is_dry_run; then
    log "DRY_RUN=yes active. No destructive or modifying commands will be executed."
  fi

  preflight_storage_checks

  log "Pre-flight storage status:"
  pvesm status

  log "Pre-flight thin-pool status:"
  lvs -a -o lv_name,vg_name,lv_size,data_percent,metadata_percent,origin,pool_lv || true

  for ctid in "$@"; do
    repair_ct "$ctid"
  done

  log "Final thin-pool status:"
  lvs -a -o lv_name,vg_name,lv_size,data_percent,metadata_percent,origin,pool_lv || true

  if is_dry_run; then
    log "Dry-run finished. No CTs were modified."
  else
    log "All requested CT repairs finished"
  fi
}

main "$@"
