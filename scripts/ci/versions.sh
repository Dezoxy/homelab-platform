#!/usr/bin/env bash
# Single source of truth for all pinned CI tool versions.
#
# Usage in shell scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/versions.sh"
#
# Usage in GitHub Actions workflow steps (sets env vars for subsequent steps):
#   grep -E '^[A-Za-z_][A-Za-z0-9_]*=' scripts/ci/versions.sh | tr -d '"' >> "$GITHUB_ENV"
#
# When bumping a version, update it here only.
# The workflow env: blocks for these tools have been removed in favour of this file.

# shellcheck disable=SC2034  # variables are consumed by scripts that source this file
TERRAFORM_VERSION="1.15.9"
PACKER_VERSION="1.16.0"
ANSIBLE_VERSION="14.3.1"
ANSIBLE_LINT_VERSION="26.8.0"
TAILSCALE_VERSION="1.96.4"
ACTIONLINT_VERSION="1.7.12"
TFLINT_VERSION="0.64.0"
CHECKOV_VERSION="3.3.13"
COMMUNITY_DOCKER_VERSION="5.2.2"
