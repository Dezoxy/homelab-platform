#!/usr/bin/env bash
set -euo pipefail

target="${TARGET:-}"
if [ -z "${target}" ]; then
  echo "TARGET env var is required" >&2
  exit 1
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

service_play="ansible/playbooks/services/${target}.yml"
play="${ANSIBLE_PLAY:-${service_play}}"
default_limit="${target}"
limit="${ANSIBLE_LIMIT:-${default_limit}}"
attested_limit="${ANSIBLE_ATTEST_LIMIT:-${default_limit}}"
inv="${ANSIBLE_INVENTORY:-ansible/inventory.ini}"
# Auto-bootstrap LXC targets: runner user may not exist on a fresh container.
# Override with ANSIBLE_BOOTSTRAP=false to skip even for LXCs.
_default_bootstrap=false
[[ "${target}" == *-lxc ]] && _default_bootstrap=true
bootstrap="${ANSIBLE_BOOTSTRAP:-${_default_bootstrap}}"
runtime_known_hosts_created=""

if [ ! -f "${inv}" ]; then
  echo "Ansible inventory not found: ${inv}" >&2
  exit 1
fi
if [ ! -f "${play}" ]; then
  echo "Ansible playbook not found: ${play}" >&2
  exit 1
fi

prepare_attested_guest_ssh_trust() {
  if [ -z "${ANSIBLE_KNOWN_HOSTS_FILE:-}" ]; then
    ANSIBLE_KNOWN_HOSTS_FILE="$(mktemp "${TMPDIR:-/tmp}/homelab-attested-known-hosts.XXXXXX")"
    runtime_known_hosts_created="${ANSIBLE_KNOWN_HOSTS_FILE}"
    export ANSIBLE_KNOWN_HOSTS_FILE
  fi
  python3 "${repo_root}/scripts/ci/build_attested_ssh_known_hosts.py" \
    --limit "${attested_limit}" \
    --output "${ANSIBLE_KNOWN_HOSTS_FILE}"
}

cleanup() {
  [ -z "${runtime_known_hosts_created}" ] || rm -f "${runtime_known_hosts_created}"
}
trap cleanup EXIT

bootstrap_lxc_users() {
  local bootstrap_play="ansible/playbooks/bootstrap/00-bootstrap-users.yml"
  if [ "${bootstrap}" != "true" ]; then
    return 0
  fi
  if [ ! -f "${bootstrap_play}" ]; then
    echo "Bootstrap playbook not found: ${bootstrap_play}" >&2
    exit 1
  fi

  echo "Bootstrap: trying root (first-boot case)..."
  if ansible-playbook -i "${inv}" "${bootstrap_play}" --limit "${limit}" \
    -e "ansible_user=root ansible_ssh_private_key_file=${HOME}/.ssh/toomhorvath"; then
    return 0
  fi

  echo "Bootstrap: root SSH failed; trying runner (steady-state case)..."
  if ansible-playbook -i "${inv}" "${bootstrap_play}" --limit "${limit}" \
    -e "ansible_user=runner ansible_ssh_private_key_file=${HOME}/.ssh/runner"; then
    return 0
  fi

  echo "Bootstrap: runner SSH failed; trying toomhorvath (legacy/hand-bootstrapped case)..."
  ansible-playbook -i "${inv}" "${bootstrap_play}" --limit "${limit}" \
    -e "ansible_user=toomhorvath ansible_ssh_private_key_file=${HOME}/.ssh/toomhorvath"
}

if [ "${RUN_TERRAFORM:-false}" = "true" ]; then
  bash scripts/ci/ensure_target_image.sh
  TF_DIR="infra-proxmox/terraform/${target}" bash scripts/ci/terraform_apply.sh
fi

if [ "${RUN_ANSIBLE:-true}" != "true" ]; then
  exit 0
fi

prepare_attested_guest_ssh_trust
bootstrap_lxc_users

extra_vars=()
ansible_user_override=""
ansible_key_override="${HOME}/.ssh/toomhorvath"

# Translate ANSIBLE_RUN_* overrides to Ansible variables checked inside each play.
if [ "${ANSIBLE_RUN_EXPAND_ROOTFS:-true}" != "true" ]; then
  extra_vars+=("-e" "rootfs_expand_enabled=false")
fi
if [ "${ANSIBLE_RUN_SYSTEM_UPDATES:-true}" != "true" ]; then
  extra_vars+=("-e" "auto_upgrade=false")
fi

target_secrets="${ANSIBLE_TARGET_SECRETS:-}"
if [ -z "${target_secrets}" ]; then
  target_secrets=false
  [ "${play}" = "${service_play}" ] && target_secrets=true
fi

if [ "${target_secrets}" = "true" ]; then
  case "${target}" in
  01-dns-lxc)
    if [ -z "${ADGUARD_USER:-}" ] || [ -z "${ADGUARD_PW:-}" ]; then
      echo "Missing required secrets: ADGUARD_USER and ADGUARD_PW" >&2
      exit 1
    fi
    extra_vars+=("-e" "adguard_admin_user=${ADGUARD_USER}")
    extra_vars+=("-e" "adguard_admin_password=${ADGUARD_PW}")
    ;;
  01-edge-lxc)
    if [ -z "${CLOUDFLARED_TUNNEL_TOKEN:-}" ]; then
      echo "Missing required secret: CLOUDFLARED_TUNNEL_TOKEN" >&2
      exit 1
    fi
    extra_vars+=("-e" "cloudflared_tunnel_token=${CLOUDFLARED_TUNNEL_TOKEN}")
    ;;
  01-reverse-proxy-lxc)
    if [ -z "${CLOUDFLARE_DNS_API_TOKEN:-}" ]; then
      echo "Missing required secret: CLOUDFLARE_DNS_API_TOKEN" >&2
      exit 1
    fi
    extra_vars+=("-e" "traefik_cloudflare_dns_token=${CLOUDFLARE_DNS_API_TOKEN}")
    ;;
  01-torrent-lxc)
    if [ -z "${QBITTORRENT_USERNAME:-}" ] || [ -z "${QBITTORRENT_PASSWORD:-}" ]; then
      echo "Missing required secrets: QBITTORRENT_USERNAME and QBITTORRENT_PASSWORD" >&2
      exit 1
    fi
    extra_vars+=("-e" "qbittorrent_api_username=${QBITTORRENT_USERNAME}")
    extra_vars+=("-e" "qbittorrent_api_password=${QBITTORRENT_PASSWORD}")
    ;;
  01-observability-lxc)
    if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
      echo "Missing required secret: GRAFANA_ADMIN_PASSWORD" >&2
      exit 1
    fi
    extra_vars+=("-e" "observability_grafana_admin_password=${GRAFANA_ADMIN_PASSWORD}")
    if [ -n "${GRAFANA_ADMIN_USER:-}" ]; then
      extra_vars+=("-e" "observability_grafana_admin_user=${GRAFANA_ADMIN_USER}")
    fi
    ;;
  01-tailscale-lxc)
    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
      extra_vars+=("-e" "tailscale_auth_key=${TAILSCALE_AUTHKEY}")
    fi
    ;;
  01-backup-lxc)
    if [ -z "${RESTIC_APPDATA_REPOSITORY:-}" ] || [ -z "${RESTIC_APPDATA_PASSWORD:-}" ] || [ -z "${B2_S3_KEY_ID:-}" ] || [ -z "${B2_S3_APPLICATION_KEY:-}" ]; then
      echo "Missing required secrets: RESTIC_APPDATA_REPOSITORY, RESTIC_APPDATA_PASSWORD, B2_S3_KEY_ID, B2_S3_APPLICATION_KEY" >&2
      exit 1
    fi
    extra_vars+=("-e" "restic_appdata_repository=${RESTIC_APPDATA_REPOSITORY}")
    extra_vars+=("-e" "restic_appdata_password=${RESTIC_APPDATA_PASSWORD}")
    extra_vars+=("-e" "restic_appdata_aws_access_key_id=${B2_S3_KEY_ID}")
    extra_vars+=("-e" "restic_appdata_aws_secret_access_key=${B2_S3_APPLICATION_KEY}")
    extra_vars+=("-e" "restic_appdata_backup_enabled=true")
    if [ -n "${RESTIC_APPDATA_AWS_DEFAULT_REGION:-}" ]; then
      extra_vars+=("-e" "restic_appdata_aws_default_region=${RESTIC_APPDATA_AWS_DEFAULT_REGION}")
    fi
    # AWS secondary restic backup is currently disabled.
    # if [ -n "${AWS_APPDATA_BACKUP_PATH:-}" ]; then
    #   if [ -z "${AWS_APPDATA_BUCKET_ACCESS_KEY:-}" ] || [ -z "${AWS_APPDATA_BUCKET_SECRET_ACCESS_KEY:-}" ]; then
    #     echo "Missing required AWS secondary backup secrets: AWS_APPDATA_BUCKET_ACCESS_KEY and AWS_APPDATA_BUCKET_SECRET_ACCESS_KEY" >&2
    #     exit 1
    #   fi
    #   extra_vars+=("-e" "restic_appdata_secondary_enabled=true")
    #   extra_vars+=("-e" "restic_appdata_secondary_repository=${AWS_APPDATA_BACKUP_PATH}")
    #   extra_vars+=("-e" "restic_appdata_secondary_aws_access_key_id=${AWS_APPDATA_BUCKET_ACCESS_KEY}")
    #   extra_vars+=("-e" "restic_appdata_secondary_aws_secret_access_key=${AWS_APPDATA_BUCKET_SECRET_ACCESS_KEY}")
    #   if [ -n "${AWS_APPDATA_AWS_DEFAULT_REGION:-}" ]; then
    #     extra_vars+=("-e" "restic_appdata_secondary_aws_default_region=${AWS_APPDATA_AWS_DEFAULT_REGION}")
    #   fi
    # fi
    if [ -n "${RESTIC_NOTIFY_NTFY_TOPIC:-}" ]; then
      extra_vars+=("-e" "restic_notify_ntfy_topic=${RESTIC_NOTIFY_NTFY_TOPIC}")
      if [ -n "${RESTIC_NOTIFY_NTFY_URL:-}" ]; then
        extra_vars+=("-e" "restic_notify_ntfy_url=${RESTIC_NOTIFY_NTFY_URL}")
      fi
      if [ -n "${RESTIC_NOTIFY_NTFY_TOKEN:-}" ]; then
        extra_vars+=("-e" "restic_notify_ntfy_token=${RESTIC_NOTIFY_NTFY_TOKEN}")
      fi
    fi
    if [ -n "${RESTIC_NOTIFY_TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${RESTIC_NOTIFY_TELEGRAM_CHAT_ID:-}" ]; then
      extra_vars+=("-e" "restic_notify_telegram_bot_token=${RESTIC_NOTIFY_TELEGRAM_BOT_TOKEN}")
      extra_vars+=("-e" "restic_notify_telegram_chat_id=${RESTIC_NOTIFY_TELEGRAM_CHAT_ID}")
    fi
    ;;
  esac
fi

if [[ "${target}" == *-lxc ]]; then
  ansible_user_override="runner"
  ansible_key_override="${HOME}/.ssh/runner"
fi
if [ -n "${ansible_user_override}" ]; then
  extra_vars+=("-e" "ansible_user=${ansible_user_override}")
fi
if [ -n "${ansible_key_override}" ]; then
  extra_vars+=("-e" "ansible_ssh_private_key_file=${ansible_key_override}")
fi

# Dry run support. `make deploy-check` used to build its own ansible-playbook
# command with four -e flags; this script injects twenty-nine, so any host whose
# role asserted on one of the other twenty-five failed the dry run for a reason
# that had nothing to do with the host -- e.g. 01-edge-lxc's
# "Set cloudflared_tunnel_token in host_vars". A preview has to run the same
# code path as the thing it is previewing, so deploy-check now calls this script
# with ANSIBLE_CHECK_MODE=true instead of reimplementing part of it.
check_args=()
if [ "${ANSIBLE_CHECK_MODE:-false}" = "true" ]; then
  check_args=(--check --diff)
fi

ansible-playbook -i "${inv}" "${play}" --limit "${limit}" "${extra_vars[@]}" ${check_args[@]+"${check_args[@]}"}
