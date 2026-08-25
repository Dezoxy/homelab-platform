# GitHub Actions Secrets and Azure Key Vault Reference

Runtime secrets are stored in Azure Key Vault and fetched by GitHub Actions through the local `.github/actions/azure-secrets` action, which authenticates to Azure via GitHub OIDC (no stored client secret). The repository needs GitHub Actions **variables** so the workflows know which vault and identity to use.

Configure these at **Settings -> Secrets and variables -> Actions -> Variables**:

| Variable | Description |
|---|---|
| `AZURE_KEYVAULT_NAME` | Key Vault name, e.g. `kv-homelab-prod` |
| `AZURE_CLIENT_ID` | Entra application (client) ID with a GitHub OIDC federated credential |
| `AZURE_TENANT_ID` | Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID containing the vault |

The remaining values below are Key Vault secrets, grouped by their `folder` tag (e.g. `tailscale`, `proxmox`, `terraform`, `ssh`, `ci`). Each secret's original env-var name is preserved in its `envvar` tag and restored on fetch; the stored secret name is a lowercased `folder-name` slug (Key Vault names allow only letters, digits, and dashes).

---

## garmin-health (deploy of 01-myapps-vm)

Folder tag: `garmin`. Consumed via `lookup('env', ...)` in
`ansible/playbooks/services/01-myapps-vm.yml`.

| Secret | Required | Description |
|---|---|---|
| `GARMIN_GHCR_PULL_TOKEN` | Yes | `read:packages` PAT for the private `ghcr.io/dezoxy/my-health-datas` image |
| `GARMIN_TELEGRAM_BOT_TOKEN` | Yes | Dedicated health bot — carries the monthly report and this service's failure alerts |
| `GARMIN_TELEGRAM_CHAT_ID` | Yes | The owner's private chat for the above |

Deliberately a separate bot and chat from `DIGEST_TELEGRAM_NOTIFY_*`: personal
health data must not share a credential or a group with the news digest.

No Garmin account and no Anthropic credential is stored here. Both
authenticate from persisted login directories inside
`/srv/appdata/garmin-health`, created by one-time interactive logins on the VM
— neither can be done unattended, so neither is a secret.

---

## Tailscale (LAN-connected workflows)

Required by workflows that need to reach the home LAN, such as Terraform plan, deploy, Packer build, and maintenance workflows.

| Secret | Description |
|---|---|
| `TAILSCALE_OAUTH_CLIENT_ID` | Tailscale OAuth client ID (tag: `tag:github-ci`) |
| `TAILSCALE_OAUTH_SECRET` | Tailscale OAuth client secret |

---

## SSH Keys (deploy + all maintenance workflows)

Two SSH user key pairs are in use. Private keys can be stored as raw PEM or
base64; the preparation script also accepts the legacy Ansible aliases.

Server host public keys are not secrets and are not stored in Key Vault. The
committed `ansible/ssh_known_hosts` file pins only `pve`; local and CI runs use
trusted `pve` to generate temporary verification entries for guest hosts.

| Secret | Description |
|---|---|
| `TOOMHORVATH_SSH_PRIVATE_KEY` | Admin user private key (PEM) |
| `TOOMHORVATH_SSH_PRIVATE_KEY_B64` | Admin user private key (base64-encoded PEM) |
| `TOOMHORVATH_SSH_PUBLIC_KEY` | Admin user public key |
| `RUNNER_SSH_PRIVATE_KEY` | `runner` service account private key (PEM) |
| `RUNNER_SSH_PRIVATE_KEY_B64` | `runner` service account private key (base64-encoded PEM) |
| `RUNNER_SSH_PUBLIC_KEY` | `runner` service account public key |
| `ANSIBLE_SSH_PRIVATE_KEY` | Legacy/alias for Ansible SSH private key (PEM) |
| `ANSIBLE_SSH_PRIVATE_KEY_B64` | Legacy/alias for Ansible SSH private key (base64-encoded PEM) |

---

## Proxmox (deploy + terraform-plan + packer-build)

| Secret | Required | Description |
|---|---|---|
| `PROXMOX_API_URL` | Yes | Proxmox REST API URL, e.g. `https://pve.lan:8006` |
| `PROXMOX_TOKEN_ID` | Yes | Proxmox API token ID, e.g. `terraform@pam!ci` |
| `PROXMOX_TOKEN_SECRET` | Yes | Proxmox API token secret |
| `TF_VAR_BOOTSTRAP_PASSWORD` | Yes | Root/bootstrap password set on new VMs during provisioning |
| `PROXMOX_ROOT_PASSWORD` | Yes | Proxmox root password (used by support-access for SSH fallback) |
| `PROXMOX_ROOT_USERNAME` | No | Proxmox root user, defaults to `root@pam` |

---

## Terraform Cloud (deploy + terraform-plan)

| Secret | Description |
|---|---|
| `TF_TOKEN_APP_TERRAFORM_IO` | HCP Terraform (app.terraform.io) API token |

---

## GitHub Actions Telegram notifications

Recommended dedicated secrets for workflow notifications:

| Secret | Required | Description |
|---|---|---|
| `ACTIONS_TELEGRAM_BOT_TOKEN` | No | Dedicated Telegram bot token for GitHub Actions notifications |
| `ACTIONS_TELEGRAM_CHAT_ID` | No | Telegram chat or group ID for GitHub Actions notifications |

If these are not set, the notification workflow falls back to:

- `GRAFANA_ALERTS_TELEGRAM_BOT_TOKEN`
- `RESTIC_NOTIFY_TELEGRAM_BOT_TOKEN`

and for the chat ID:

- `GRAFANA_ALERTS_TELEGRAM_CHAT_ID`
- `RESTIC_NOTIFY_TELEGRAM_CHAT_ID`

---

## GitHub Actions repository settings

These are repository settings, not secrets, but the automation workflows need them:

1. In GitHub, open `Settings -> Actions -> General`.
2. Under `Workflow permissions`, select `Read and write permissions`.
3. Enable `Allow GitHub Actions to create and approve pull requests`.

Without those settings, the auto PR workflow cannot open or merge PRs with `GITHUB_TOKEN`.

---

## Packer Runtime Exports

Packer does not need additional Key Vault secrets beyond the `proxmox` folder.
`scripts/ci/export_runtime_env.sh packer` maps the existing Proxmox
secret names to Packer's environment variable convention:

| `/proxmox` secret | Runtime export |
|---|---|
| `PROXMOX_API_URL` | `PKR_VAR_proxmox_url` |
| `PROXMOX_TOKEN_ID` | `PKR_VAR_proxmox_token_id` |
| `PROXMOX_TOKEN_SECRET` | `PKR_VAR_proxmox_token_secret` |

---

## Per-service secrets (deploy only)

Each secret is only used when deploying the corresponding target.

**`scripts/ci/target_secret_folders.sh` is the source of truth** for which
folders a deploy fetches. Verified 2026-08-25:

| Target | Service folders (on top of `proxmox,terraform,ssh,tailscale`) |
|---|---|
| `01-media-vm` | `media` |
| `01-myapps-vm` | `digest`, `chromium`, `jobs-refresh`, `garmin` |
| `01-unifi-vm` | `unifi` |
| `01-code-lxc` | `agent` |
| `01-backup-lxc` | `backup` |
| `01-dns-lxc` | `dns` |
| `01-edge-lxc` | `edge` |
| `01-observability-lxc` | `observability`, `dns`, `backup` |
| `01-reverse-proxy-lxc` | `reverse-proxy` |
| `01-tailscale-lxc` | *(machinery only)* |
| `01-torrent-lxc` | `torrent` |

Some vault folders are **not** deploy folders and appear in no row above —
`ci` (GitHub Actions notifications), `cloudflare`, `dashboard`, `mcp`,
`openclaw` and `root` are consumed by other tooling. Presence in the vault does
not imply a deploy reads it.

### `01-dns-lxc` — AdGuard Home
| Secret | Description |
|---|---|
| `ADGUARD_USER` | AdGuard Home admin username |
| `ADGUARD_PW` | AdGuard Home admin password |

### `01-edge-lxc` — Cloudflare Tunnel
| Secret | Description |
|---|---|
| `CLOUDFLARED_TUNNEL_TOKEN` | Cloudflared tunnel token |

### `01-reverse-proxy-lxc` — Traefik
| Secret | Description |
|---|---|
| `CLOUDFLARE_DNS_API_TOKEN` | Cloudflare API token with DNS edit permissions (for ACME) |

### `01-observability-lxc` — Grafana
| Secret | Description |
|---|---|
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password |
| `GRAFANA_ALERTS_TELEGRAM_BOT_TOKEN` | Optional dedicated Telegram bot token for Grafana alerts. If omitted, deploy falls back to `RESTIC_NOTIFY_TELEGRAM_BOT_TOKEN`. |
| `GRAFANA_ALERTS_TELEGRAM_CHAT_ID` | Optional Telegram chat/group ID for Grafana alerts. If omitted, deploy falls back to `RESTIC_NOTIFY_TELEGRAM_CHAT_ID`. |

### `01-torrent-lxc` — qBittorrent
| Secret | Required | Description |
|---|---|---|
| `QBITTORRENT_USERNAME` | Yes | qBittorrent Web API username for enforcing live preferences and categories |
| `QBITTORRENT_PASSWORD` | Yes | qBittorrent Web API password |

### `01-tailscale-lxc` — Tailscale node
| Secret | Description |
|---|---|
| `TAILSCALE_AUTHKEY` | Tailscale auth key for the dedicated Tailscale LXC |

### `01-unifi-vm` — UniFi OS Server
| Secret | Required | Description |
|---|---|---|
| `UNIFI_DDNS_CF_API_TOKEN` | Yes | Cloudflare API token for the DDNS updater. Scope it **`Zone:DNS:Edit` on `example.net` only** — deliberately not `CLOUDFLARE_DNS_API_TOKEN`, which can also rewrite the primary zone and is used by a different host |

> `UNIFI_MONGO_PASSWORD` and `UNIFI_MONGO_ROOT_PASSWORD` are no longer used.
> They belonged to the retired `01-unifi-lxc`, which ran its own MongoDB;
> UniFi OS Server manages its database internally. Both can be deleted from the
> `unifi` Key Vault folder. See [unifi.md](unifi.md).

### `01-backup-lxc` — Restic / Backblaze B2
| Secret | Required | Description |
|---|---|---|
| `RESTIC_APPDATA_REPOSITORY` | Yes | Restic repository URL (S3-compatible), e.g. `s3:s3.us-west-004.backblazeb2.com/bucket` |
| `RESTIC_APPDATA_PASSWORD` | Yes | Restic repository encryption password |
| `B2_S3_KEY_ID` | Yes | Backblaze B2 application key ID |
| `B2_S3_APPLICATION_KEY` | Yes | Backblaze B2 application key |
| `RESTIC_APPDATA_AWS_DEFAULT_REGION` | No | B2 region, e.g. `us-west-004` |
| `RESTIC_NOTIFY_NTFY_URL` | No | ntfy server URL for backup notifications |
| `RESTIC_NOTIFY_NTFY_TOPIC` | No | ntfy topic for backup notifications |
| `RESTIC_NOTIFY_NTFY_TOKEN` | No | ntfy auth token |
| `RESTIC_NOTIFY_TELEGRAM_BOT_TOKEN` | No | Telegram bot token for backup notifications |
| `RESTIC_NOTIFY_TELEGRAM_CHAT_ID` | No | Telegram chat ID for backup notifications |
| `BACKUP_SMB_PASSWORD` | No | Samba password for the `tmuser` account on `macbook-backup` |
<!-- AWS secondary restic backup is currently disabled.
| `AWS_APPDATA_BUCKET_ACCESS_KEY` | No | Access key for the optional secondary AWS S3 appdata restic repo |
| `AWS_APPDATA_BUCKET_SECRET_ACCESS_KEY` | No | Secret access key for the optional secondary AWS S3 appdata restic repo |

Optional repository variables for the secondary AWS target:

| Variable | Description |
|---|---|
| `AWS_APPDATA_BACKUP_PATH` | Secondary AWS S3 restic repository URL, e.g. `s3:s3.eu-north-1.amazonaws.com/bucket/path` |
| `AWS_APPDATA_AWS_DEFAULT_REGION` | Optional explicit AWS region override; if omitted, the backup script derives it from a standard `s3.<region>.amazonaws.com` endpoint when possible |
-->

### `01-code-lxc` — code-server

Uses the **`agent`** folder, which it inherited rather than replacing. The
folder was created for the retired `01-agent-lxc`; keeping it meant
`CODE_SERVER_PASSWORD` survived that retirement and the replacement host could
adopt it instead of minting a second copy.

| Secret | Required | Description |
|---|---|---|
| `CODE_SERVER_PASSWORD` | Yes | code-server login, behind Cloudflare Access |
| `OPENROUTER_API_KEY` | No | left from the retired host's CLI tooling |

(An earlier revision of this document said the `agent` folder was "no longer
read by anything" and listed an `OPENAI_API_KEY`. Both were wrong as of
2026-08-25: `scripts/ci/target_secret_folders.sh` maps `01-code-lxc` to `agent`,
and the vault holds no `OPENAI_API_KEY`.)

### `01-media-vm` — media stack

Folder **`media`**: `KOMETA_PLEX_TOKEN`, `KOMETA_TMDB_APIKEY`,
`OBSIDIAN_EMAIL`, `OBSIDIAN_PASSWORD`.

### `01-myapps-vm` — self-hosted apps and jobs

Four folders: **`digest`** (18 secrets — SMTP, Telegram, Telethon, Reddit/X/
Patreon sessions, site ingest), **`chromium`** (`CHROMIUM_UI_PASSWORD`),
**`jobs-refresh`** (tracker OAuth pair + Telegram), and **`garmin`** (see the
garmin-health section above).
