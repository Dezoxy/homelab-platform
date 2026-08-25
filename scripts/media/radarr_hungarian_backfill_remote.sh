#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/home/toomhorvath/radarr-hungarian-backfill"
SCRIPT_PATH="$BASE_DIR/radarr_hungarian_backfill.py"
STATE_PATH="$BASE_DIR/state.json"
OUTPUT_PATH="$BASE_DIR/latest.json"
LOCK_PATH="$BASE_DIR/run.lock"
LOG_PATH="$BASE_DIR/runner.log"
ENV_PATH="$BASE_DIR/run-backfill.env"

mkdir -p "$BASE_DIR"
if [ -r "$ENV_PATH" ]; then
  # shellcheck source=/dev/null
  . "$ENV_PATH"
fi

{
  echo "[$(date --iso-8601=seconds)] start"

  /usr/bin/flock -n "$LOCK_PATH" /usr/bin/python3 "$SCRIPT_PATH" \
    --base-url http://127.0.0.1:7878 \
    --config-path /srv/appdata/radarr/config.xml \
    --batch-size 10 \
    --max-active-queue 20 \
    --qbittorrent-url "${QBITTORRENT_URL:-http://192.168.1.71:8080}" \
    --qbittorrent-username "${QBITTORRENT_USERNAME:-}" \
    --qbittorrent-password "${QBITTORRENT_PASSWORD:-}" \
    --qbittorrent-category "${QBITTORRENT_CATEGORY:-movies-radarr}" \
    --qbittorrent-count-mode "${QBITTORRENT_COUNT_MODE:-incomplete}" \
    --inspect-limit 60 \
    --include-unmonitored \
    --apply \
    --state-file "$STATE_PATH" \
    --output-json "$OUTPUT_PATH"

  set +e
  /usr/bin/python3 - "$OUTPUT_PATH" <<'PY'
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
payload = json.loads(output_path.read_text(encoding="utf-8"))
if payload.get("backfillCompleted"):
    raise SystemExit(10)
raise SystemExit(0)
PY
  status=$?
  set -e

  if [ "$status" -eq 10 ]; then
    tmp="$(mktemp)"
    if crontab -l >/dev/null 2>&1; then
      crontab -l | sed '/# BEGIN radarr-hungarian-backfill/,/# END radarr-hungarian-backfill/d' > "$tmp"
    else
      : > "$tmp"
    fi
    crontab "$tmp"
    rm -f "$tmp"
    echo "[$(date --iso-8601=seconds)] backfill complete, cron entry removed"
  fi

  echo "[$(date --iso-8601=seconds)] end"
} >>"$LOG_PATH" 2>&1
