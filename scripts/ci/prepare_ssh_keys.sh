#!/usr/bin/env bash
set -euo pipefail

emit_env() {
  local key="$1"
  local value="$2"
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s=%s\n' "${key}" "${value}" >>"${GITHUB_ENV}"
  else
    printf 'export %s=%q\n' "${key}" "${value}"
  fi
}

write_private_key() {
  local key_path="$1"
  local key_b64="${2:-}"
  local key_raw="${3:-}"
  local tmp_path
  tmp_path="${key_path}.tmp"

  validate_key_file() {
    local candidate="$1"
    chmod 600 "${candidate}"
    ssh-keygen -y -f "${candidate}" >/dev/null 2>&1
  }

  if [ -n "${key_b64}" ]; then
    if printf '%s' "${key_b64}" | base64 -d >"${tmp_path}" 2>/dev/null; then
      if validate_key_file "${tmp_path}"; then
        mv "${tmp_path}" "${key_path}"
        return 0
      fi
    fi

    # Some CI secrets may already contain raw key material despite the _B64 suffix.
    printf '%s\n' "${key_b64}" >"${tmp_path}"
    if validate_key_file "${tmp_path}"; then
      mv "${tmp_path}" "${key_path}"
      return 0
    fi
  fi

  if [ -n "${key_raw}" ]; then
    printf '%s\n' "${key_raw}" >"${tmp_path}"
    if validate_key_file "${tmp_path}"; then
      mv "${tmp_path}" "${key_path}"
      return 0
    fi
  fi

  rm -f "${tmp_path}"
  return 1
}

install -d -m 0700 "${HOME}/.ssh"

if ! write_private_key \
  "${HOME}/.ssh/toomhorvath" \
  "${TOOMHORVATH_SSH_PRIVATE_KEY_B64:-${ANSIBLE_SSH_PRIVATE_KEY_B64:-}}" \
  "${TOOMHORVATH_SSH_PRIVATE_KEY:-${ANSIBLE_SSH_PRIVATE_KEY:-}}"; then
  echo "Missing required secret: TOOMHORVATH_SSH_PRIVATE_KEY(_B64) (or legacy ANSIBLE_SSH_PRIVATE_KEY(_B64))" >&2
  exit 1
fi
chmod 600 "${HOME}/.ssh/toomhorvath"
ssh-keygen -y -f "${HOME}/.ssh/toomhorvath" >/dev/null

if ! write_private_key \
  "${HOME}/.ssh/runner" \
  "${RUNNER_SSH_PRIVATE_KEY_B64:-}" \
  "${RUNNER_SSH_PRIVATE_KEY:-}"; then
  cp "${HOME}/.ssh/toomhorvath" "${HOME}/.ssh/runner"
fi
chmod 600 "${HOME}/.ssh/runner"
ssh-keygen -y -f "${HOME}/.ssh/runner" >/dev/null

repo_root="${GITHUB_WORKSPACE:-}"
if [ -z "${repo_root}" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
mkdir -p "${repo_root}/keys"

# Always derive public keys from the private keys we will actually use for SSH.
# This avoids mismatches between *_SSH_PUBLIC_KEY and *_SSH_PRIVATE_KEY secrets.
runner_pubkey="$(ssh-keygen -y -f "${HOME}/.ssh/runner")"
toom_pubkey="$(ssh-keygen -y -f "${HOME}/.ssh/toomhorvath")"

# Optional warning if a public-key secret doesn't match the derived key (ignoring the comment field).
if [ -n "${RUNNER_SSH_PUBLIC_KEY:-}" ]; then
  derived_runner_fp="$(printf '%s\n' "${runner_pubkey}" | awk '{print $1, $2}')"
  secret_runner_fp="$(printf '%s\n' "${RUNNER_SSH_PUBLIC_KEY}" | awk '{print $1, $2}')"
  if [ "${derived_runner_fp}" != "${secret_runner_fp}" ]; then
    echo "WARN: RUNNER_SSH_PUBLIC_KEY does not match RUNNER_SSH_PRIVATE_KEY; using derived public key."
  fi
fi
if [ -n "${TOOMHORVATH_SSH_PUBLIC_KEY:-}" ]; then
  derived_toom_fp="$(printf '%s\n' "${toom_pubkey}" | awk '{print $1, $2}')"
  secret_toom_fp="$(printf '%s\n' "${TOOMHORVATH_SSH_PUBLIC_KEY}" | awk '{print $1, $2}')"
  if [ "${derived_toom_fp}" != "${secret_toom_fp}" ]; then
    echo "WARN: TOOMHORVATH_SSH_PUBLIC_KEY does not match TOOMHORVATH_SSH_PRIVATE_KEY; using derived public key."
  fi
fi

# Terraform uses admin_pubkey as the primary login key; runner.pub is included separately.
emit_env "TF_VAR_admin_pubkey" "${toom_pubkey}"
printf '%s\n' "${toom_pubkey}" >"${repo_root}/keys/toomhorvath.pub"
printf '%s\n' "${runner_pubkey}" >"${repo_root}/keys/runner.pub"

emit_env "RUNNER_SSH_PUBKEY" "${runner_pubkey}"
