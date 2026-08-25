#!/usr/bin/env bash
# Single source of truth: which Key Vault folders a *deploy* of <target> needs.
#
# Prints a comma-separated folder list for AZURE_KEYVAULT_FOLDER (consumed by
# scripts/dev/azure_kv_run.sh locally and the azure-secrets action in CI), so a
# deploy fetches only the secrets that target actually uses — not the whole vault.
#
# Every deploy needs the MACHINERY folders:
#   proxmox    - Terraform Proxmox provider + TF_VAR_BOOTSTRAP_PASSWORD
#   terraform  - TF_TOKEN_APP_TERRAFORM_IO (HCP remote state)
#   ssh        - runner/admin SSH keys for the Ansible connection
#   tailscale  - TAILSCALE_OAUTH_* (CI LAN connect) + TAILSCALE_AUTHKEY (node)
#
# Per-target service folders below cover BOTH what run_ansible.sh injects as
# extra_vars AND what playbooks/roles read via lookup('env', ...). Keep this in
# sync when a play starts consuming a secret from a new folder — note the
# cross-folder cases (e.g. observability also reads dns + backup secrets).
set -euo pipefail

target="${1:?usage: target_secret_folders.sh <target>}"
machinery="proxmox,terraform,ssh,tailscale"

case "$target" in
  01-dns-lxc)           svc="dns" ;;
  01-edge-lxc)          svc="edge" ;;
  01-reverse-proxy-lxc) svc="reverse-proxy" ;;
  01-torrent-lxc)       svc="torrent" ;;
  01-backup-lxc)        svc="backup" ;;
  01-media-vm)          svc="media" ;;
  # observability reads GRAFANA_* (observability) + ADGUARD_* (dns exporter)
  # + RESTIC_NOTIFY_TELEGRAM_* (alert fallback, backup) via lookup('env').
  01-observability-lxc) svc="observability,dns,backup" ;;
  # TAILSCALE_AUTHKEY lives in the tailscale folder already in machinery.
  01-tailscale-lxc)     svc="" ;;
  # notification-digest reads TG_*/SMTP_* secrets (DIGEST_TG_API_ID, etc.)
  # from the digest folder via lookup('env', ...) in 01-myapps-vm.yml.
  # chromium is its own folder rather than riding digest's: the browser UI
  # password has nothing to do with the digest service, and a folder name that
  # lies about scope is worse than an extra entry here. jobs-refresh follows
  # the same rule: its Access service token (JOBS_TRACKER_CLIENT_ID/_SECRET,
  # for the dashboard tracker sync endpoint) and its own Telegram digest
  # credentials (JOBS_REFRESH_TELEGRAM_BOT_TOKEN/_CHAT_ID -- the "Job Agent"
  # bot, distinct from digest's alert bot) belong to the jobs-refresh
  # service, not to digest or chromium.
  # garmin gets its own folder for the same reason chromium and jobs-refresh
  # do: its GHCR pull token and its DEDICATED health Telegram bot belong to
  # the garmin-health service, not to digest. Personal health data sharing a
  # secret folder with the news digest is exactly the coupling to avoid.
  01-myapps-vm)         svc="digest,chromium,jobs-refresh,garmin" ;;
  # UNIFI_MONGO_PASSWORD / UNIFI_MONGO_ROOT_PASSWORD / UNIFI_DDNS_CF_API_TOKEN
  # Same folder the retired 01-unifi-lxc used: 01-unifi-vm.yml owns the DDNS
  # updater and reads UNIFI_DDNS_CF_API_TOKEN through lookup('env', ...).
  # Nothing is injected as extra_vars by run_ansible.sh, so this folder mapping
  # is the only wiring.
  01-unifi-vm)          svc="unifi" ;;
  # Reuses the `agent` folder rather than getting its own: CODE_SERVER_PASSWORD
  # already lives there from the retired 01-agent-lxc, and #793 kept the folder
  # deliberately. One credential, one record -- a second copy would be free to
  # drift from the one people actually rotate.
  01-code-lxc)          svc="agent" ;;
  *) echo "Unknown deploy target: ${target}" >&2; exit 1 ;;
esac

if [ -n "$svc" ]; then
  printf '%s,%s\n' "$machinery" "$svc"
else
  printf '%s\n' "$machinery"
fi
