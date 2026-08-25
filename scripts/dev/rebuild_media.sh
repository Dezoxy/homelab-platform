#!/usr/bin/env bash
set -euo pipefail

target="01-media-vm"
required_image="ubuntu-2604-vm-v1"
manifest="$(mktemp "${TMPDIR:-/tmp}/media-rebuild-manifest.XXXXXX.json")"
runtime_known_hosts="$(mktemp "${TMPDIR:-/tmp}/media-rebuild-known-hosts.XXXXXX")"
resume_media_on_failure=false
replacement_started=false

cleanup() {
  local rc=$?
  if [ "${rc}" -ne 0 ] \
    && [ "${resume_media_on_failure}" = "true" ] \
    && [ "${replacement_started}" != "true" ]; then
    echo "Media replacement has not started; restoring the existing compose stack." >&2
    ansible -i ansible/inventory.ini "${target}" --become \
      --module-name ansible.builtin.systemd \
      --args "name=homelab-compose.service state=started" >/dev/null 2>&1 || true
  fi
  rm -f "${manifest}" "${runtime_known_hosts}"
  exit "${rc}"
}
trap cleanup EXIT

export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-ansible/ansible.cfg}"

image_id="$(
  python3 scripts/ci/resolve_image_pin.py --target "${target}" |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["image_id"])'
)"
if [ "${image_id}" != "${required_image}" ] \
  && [ "${MEDIA_REBUILD_ALLOW_CURRENT_IMAGE:-false}" != "true" ]; then
  cat >&2 <<EOF
Refusing media VM replacement: ${target} is bound to ${image_id}.

Build the Ubuntu 26.04 template first with:

  make ensure-image IMAGE=${required_image}

Then deliberately change its catalog binding to ${required_image} and rerun:

  make rebuild-media
EOF
  exit 1
fi

# Ensure the requested template is available before any media service outage.
TARGET="${target}" bash scripts/ci/ensure_target_image.sh

if [ "${MEDIA_REBUILD_CONFIRM:-false}" != "true" ]; then
  cat <<EOF

DESTRUCTIVE: replace ${target} from catalog image ${image_id}.

This operation stops the media compose stack, creates a final local-state
mirror and Backblaze/restic snapshot, then replaces the VM root disk.
EOF
  read -r -p "Continue with the media VM rebuild? [y/N] " answer
  if [ "${answer}" != "y" ]; then
    echo "Aborted."
    exit 1
  fi
fi

export ANSIBLE_KNOWN_HOSTS_FILE="${runtime_known_hosts}"
python3 scripts/ci/build_attested_ssh_known_hosts.py \
  --target "${target}" \
  --target "01-backup-lxc" \
  --output "${ANSIBLE_KNOWN_HOSTS_FILE}"
resume_media_on_failure=true
ansible-playbook \
  -i ansible/inventory.ini \
  ansible/playbooks/operations/prepare-media-rebuild.yml \
  -e "media_rebuild_manifest_local=${manifest}"

prepared_at="$(
  python3 -c 'import datetime, json, sys; v=json.load(open(sys.argv[1], encoding="utf-8")); print(datetime.datetime.fromtimestamp(v["prepared_epoch"], datetime.timezone.utc).isoformat())' "${manifest}"
)"
offsite_at="$(
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["offsite_completed_at"])' "${manifest}"
)"
printf '\nVerified stopped-state mirror: %s\nVerified offsite snapshot: %s\n\n' "${prepared_at}" "${offsite_at}"

replacement_started=true
TARGET="${target}" \
FORCE_REPLACE=true \
MEDIA_REBUILD_APPROVED=true \
MEDIA_REBUILD_MANIFEST_FILE="${manifest}" \
RUN_TERRAFORM=true \
RUN_ANSIBLE=true \
bash scripts/ci/run_ansible.sh

echo "Media VM rebuild and service restore completed from image ${image_id}."
