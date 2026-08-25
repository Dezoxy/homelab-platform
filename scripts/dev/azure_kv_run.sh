#!/usr/bin/env bash
# Run a command with secrets fetched from Azure Key Vault.
#
# Pulls secrets from the vault, exports
# them into the child process environment under their original env-var names,
# then execs the supplied command.
#
# Auth: relies on the ambient Azure CLI session (`az login`). No client secret.
# Each secret carries an `envvar` tag holding its exact env-var name (preserving
# underscores/case that Key Vault's own name grammar cannot) and a `folder` tag
# used to scope partial fetches.
set -euo pipefail

if [ "${1:-}" = "--" ]; then
  shift
fi

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 -- <command> [args...]" >&2
  exit 2
fi

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: az CLI not found" >&2
  exit 1
fi

vault="${AZURE_KEYVAULT_NAME:-}"
# Optional: restrict to one logical folder (e.g. "proxmox"); empty = all secrets.
folder="${AZURE_KEYVAULT_FOLDER:-}"

if [ -z "$vault" ]; then
  echo "ERROR: AZURE_KEYVAULT_NAME is not set" >&2
  exit 1
fi

if ! az account show >/dev/null 2>&1; then
  echo "ERROR: no active Azure session. Run 'az login' first." >&2
  exit 1
fi

# Build the server-side filter once so scoped fetches stay cheap.
# folder may be empty (all), one folder, or a comma-separated list.
if [ -z "$folder" ]; then
  query="[].{id:name, envvar:tags.envvar}"
elif [[ "$folder" == *,* ]]; then
  list=""
  IFS=',' read -ra parts <<< "$folder"
  for p in "${parts[@]}"; do
    p="${p// /}"
    [ -z "$p" ] && continue
    list="${list:+$list,}'${p}'"
  done
  query="[?contains([${list}], tags.folder)].{id:name, envvar:tags.envvar}"
else
  query="[?tags.folder=='${folder}'].{id:name, envvar:tags.envvar}"
fi

# List returns names + tags but not values; values need a per-secret show.
# (Portable read loop — macOS ships bash 3.2, which has no `mapfile`.)
rows=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  rows+=("$line")
done < <(
  az keyvault secret list \
    --vault-name "$vault" \
    --query "$query" \
    -o tsv
)

if [ "${#rows[@]}" -eq 0 ]; then
  echo "ERROR: no secrets found in vault '${vault}'${folder:+ for folder '${folder}'}" >&2
  exit 1
fi

declare -a child_env=()
fetched=0

for row in "${rows[@]}"; do
  [ -z "$row" ] && continue
  kv_name="${row%%$'\t'*}"
  env_name="${row#*$'\t'}"

  # Skip secrets missing the envvar tag — we cannot map them to a variable.
  # (When the tag is absent, az emits the row with an empty second column, so
  # the substitution above leaves env_name equal to the whole row.)
  if [ -z "$env_name" ] || [ "$env_name" = "$row" ]; then
    echo "WARNING: secret '${kv_name}' has no 'envvar' tag; skipping" >&2
    continue
  fi

  value="$(
    az keyvault secret show \
      --vault-name "$vault" \
      --name "$kv_name" \
      --query value \
      -o tsv
  )"

  child_env+=("${env_name}=${value}")
  fetched=$((fetched + 1))
done

if [ "$fetched" -eq 0 ]; then
  echo "ERROR: fetched 0 usable secrets from vault '${vault}'" >&2
  exit 1
fi

exec env "${child_env[@]}" "$@"
