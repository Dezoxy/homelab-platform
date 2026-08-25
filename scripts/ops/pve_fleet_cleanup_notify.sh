#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${PVE_FLEET_NOTIFY_ENV_FILE:-/etc/pve-fleet-cleanup/notify.env}"
TARGET_UNIT="${1:-pve-fleet-cleanup.service}"
RESULT="${2:-success}"

if [ -r "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

hostname="$(hostname -f 2>/dev/null || hostname)"
ts="$(date -Is 2>/dev/null || date)"
result_upper="$(printf '%s' "${RESULT}" | tr '[:lower:]' '[:upper:]')"

journal="$(journalctl -u "${TARGET_UNIT}" -n 120 --no-pager -o short-iso 2>/dev/null || true)"
status="$(systemctl status "${TARGET_UNIT}" --no-pager -l 2>/dev/null || true)"

title="pve fleet cleanup ${result_upper}: ${hostname}"
body="$(
  cat <<EOF
Time: ${ts}
Host: ${hostname}
Unit: ${TARGET_UNIT}
Result: ${RESULT}

Last logs (journalctl -n 120):
${journal}

Status (systemctl status):
${status}
EOF
)"

truncate_telegram() {
  local max=3900
  if [ "${#body}" -le "${max}" ]; then
    printf '%s' "${body}"
    return 0
  fi
  printf '%s' "${body:0:${max}}\n\n(truncated)"
}

send_ntfy() {
  local url="${NTFY_URL%/}/${NTFY_TOPIC}"
  local -a args
  args=(-fsS -X POST -H "Title: ${title}" -H "Tags: wrench")
  if [ "${RESULT}" != "success" ]; then
    args=(-fsS -X POST -H "Title: ${title}" -H "Tags: warning,wrench")
  fi
  if [ -n "${NTFY_TOKEN}" ]; then
    args+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
  fi
  args+=(-d "${body}" "${url}")
  curl "${args[@]}" >/dev/null 2>&1 || true
}

send_telegram() {
  local api="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
  local msg telegram_text
  msg="$(truncate_telegram)"
  telegram_text="${title}"$'\n\n'"${msg}"
  curl -fsS -X POST "${api}" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${telegram_text}" \
    -d "disable_web_page_preview=true" >/dev/null 2>&1 || true
}

sent=false
if [ -n "${NTFY_TOPIC}" ]; then
  send_ntfy
  sent=true
  echo "pve-fleet-cleanup-notify: attempted ntfy notification for ${RESULT}."
fi
if [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -n "${TELEGRAM_CHAT_ID}" ]; then
  send_telegram
  sent=true
  echo "pve-fleet-cleanup-notify: attempted telegram notification for ${RESULT}."
fi

if [ "${sent}" = false ]; then
  echo "pve-fleet-cleanup-notify: no notification target configured."
fi

exit 0
