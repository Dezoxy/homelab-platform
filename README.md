# Homelab Platform — Infrastructure as Code

> **Portfolio snapshot.** A sanitized point-in-time copy of the private repository that
> runs my home infrastructure. Real domains, email addresses and the Key Vault name are
> replaced with placeholders; git history, secrets, keys and state files are not included.
> Everything else — the Terraform modules, Ansible roles, CI workflows and documentation —
> is the code as it actually runs.

A single Proxmox node running **eleven LXC/VM guests**, managed entirely with Terraform,
Packer and Ansible. Nothing is configured by hand after the initial hypervisor install.

### What this is meant to show

- **Infrastructure as code, end to end.** Eleven Terraform stacks over two shared modules,
  Packer-built base images pinned through an immutable catalog, and one Ansible playbook per
  host. Guest inventory is generated from Terraform variable defaults rather than maintained
  by hand.
- **Secrets with no long-lived credentials.** Azure Key Vault is the single source; local
  runs use an ambient `az login`, CI authenticates via GitHub OIDC. There is no Ansible
  Vault, no in-cluster secrets service, and nothing encrypted in the repo.
- **Safety engineering where it matters.** A fail-closed pre-start hook refuses to boot a
  guest whose host storage is missing — because a media library that scans an empty mount
  deletes itself. A destructive VM replacement is gated behind a verified, time-limited
  stopped-state manifest. SQLite databases are never opened on the VirtIO-FS share, because
  they cannot be.
- **Comments that record why, not what.** Where a decision was measured, the measurement is
  in the comment: dates, numbers, and the failure that prompted it. Several of the more
  unusual-looking choices in this repo are load-bearing, and say so.

### Worth reading first

| | |
|---|---|
| [docs/platform.md](docs/platform.md) | architecture, network and storage model |
| [docs/proxmox-boot-shutdown-order.md](docs/proxmox-boot-shutdown-order.md) | boot sequencing and the fail-closed mount guard |
| [docs/compose-vm.md](docs/compose-vm.md) | why live SQLite stays off the shared filesystem |
| [ansible/roles/local_state_backup/](ansible/roles/local_state_backup/) | SQLite-safe backup with a restore path that is actually exercised |
| [docs/ci-workflows.md](docs/ci-workflows.md) | local `make` → GitHub Actions → Key Vault |

---

Single-node Proxmox homelab running eleven LXC/VM guests, managed entirely with Terraform, Packer, and Ansible. All infrastructure is code — nothing is configured by hand after the initial Proxmox install.

## Architecture at a glance

```
Internet
   │
   ▼
Cloudflare Tunnel (01-edge-lxc)
   │
   ▼
Traefik reverse proxy (01-reverse-proxy-lxc)
   │
   ├─▶ Media stack — Plex, *arr, Kometa, etc. (01-media-vm)
   ├─▶ netcheck, notification-digest, garmin-health, withings-sync,
   │   jobs-refresh — self-hosted apps and scheduled jobs (01-myapps-vm)
   └─▶ code-server — VS Code in the browser, behind Cloudflare Access (01-code-lxc)

LAN: 192.168.1.0/24  ──▶  AdGuard Home DNS (01-dns-lxc)

GitHub CI ──▶ Tailscale subnet router (01-tailscale-lxc) ──▶ LAN

Remote-site UniFi APs ──▶ inform :8080 ──▶ UniFi OS Server (01-unifi-vm)
```

## Node inventory

| Host | Type | VMID | IP | Purpose |
|---|---|---|---|---|
| 01-edge-lxc | LXC | 160 | 192.168.1.2 | Cloudflare Tunnel client |
| 01-dns-lxc | LXC | 161 | 192.168.1.3 | AdGuard Home — LAN DNS |
| 01-reverse-proxy-lxc | LXC | 162 | 192.168.1.4 | Traefik — HTTP(S) entrypoint |
| 01-tailscale-lxc | LXC | 165 | 192.168.1.7 | Tailscale subnet router for CI |
| 01-media-vm | VM | 150 | 192.168.1.70 | Docker/Compose media stack |
| 01-myapps-vm | VM | 151 | 192.168.1.72 | Docker/Compose self-hosted apps and scheduled jobs (netcheck, notification-digest, garmin-health, withings-sync, jobs-refresh) |
| 01-unifi-vm | VM | 152 | 192.168.1.75 | UniFi OS Server — manages remote-site APs |
| 01-torrent-lxc | LXC | 171 | 192.168.1.71 | qBittorrent (isolated) |
| 01-backup-lxc | LXC | 173 | 192.168.1.73 | Restic backup agent |
| 01-observability-lxc | LXC | 174 | 192.168.1.74 | Grafana, Prometheus, Loki, Tempo + adguard/blackbox/cadvisor exporters |
| 01-code-lxc | LXC | 176 | 192.168.1.78 | code-server — VS Code in the browser |

Proxmox host: `192.168.1.239`

## Secrets model

All runtime secrets live in **Azure Key Vault** (`kv-homelab-prod`, region `germanywestcentral`). Nothing encrypted is committed to this repo, and there is no in-cluster secrets service.

Each secret is stored under a slug name (`folder-name`, lowercased/dashed to satisfy Key Vault's naming grammar) with two tags: `folder` (logical grouping, e.g. `proxmox`, `ssh`) and `envvar` (the exact original env-var name, restored verbatim on fetch).

- **Local deploys** — the Makefile wraps every Ansible run in `scripts/dev/azure_kv_run.sh`. It uses your ambient `az login` session (no client secret on disk) to fetch secrets and export them under their original env-var names. Override the vault with `AZURE_KEYVAULT_NAME=<name>`.
- **GitHub Actions** — workflows authenticate to Azure via GitHub OIDC (no long-lived tokens) using a federated Entra credential, then fetch the same secrets via [`.github/actions/azure-secrets`](.github/actions/azure-secrets). See [`.github/workflows/`](.github/workflows/) and [docs/ci-workflows.md](docs/ci-workflows.md).
- **Recovery** — Key Vault has soft-delete (90-day) and purge protection enabled, so there is no bootstrap/restore dance to maintain.

## Repository layout

```
.
├── ansible/                    Ansible playbooks, roles, and host vars
│   ├── group_vars/all.yml      Shared variables across every host
│   ├── host_vars/<host>/       Per-host non-secret overrides (vars.yml)
│   ├── playbooks/services/     One playbook per managed host
│   ├── playbooks/maintenance/  Cross-host maintenance plays (apt-upgrade, etc.)
│   ├── playbooks/bootstrap/    First-boot LXC user bootstrap
│   ├── roles/                  Shared roles (docker, virtiofs_mounts,
│   │                           local_state_backup, …) — templates and files
│   │                           live inside each role
│   ├── inventory.ini           Auto-generated — do not edit by hand
│   ├── inventory-proxmox.ini   The hypervisor, kept out of guest-wide plays
│   ├── ssh_known_hosts         Pinned pve host key (root of trust)
│   ├── proxmox_guest_ssh_attestation.json   Guest → VMID map for attestation
│   └── ansible.cfg
├── infra-proxmox/
│   └── terraform/
│       ├── _shared/            Centralized provider config + shared vars
│       ├── modules/
│       │   ├── proxmox-lxc/    Shared LXC module (all LXC stacks use this)
│       │   └── proxmox-vm/     Shared VM module (all VM stacks use this)
│       └── 01-*/               One stack per host — each stack is a
│                               Terraform Cloud workspace
├── infra-images/
│   └── packer/                 Packer templates for base VM images
├── scripts/
│   ├── ci/                     Shell helpers sourced by GitHub Actions
│   │   ├── versions.sh         Single source of truth for all pinned versions
│   │   ├── run_ansible.sh      Wraps ansible-playbook with target-aware setup
│   │   └── ensure_ansible.sh   Provision the Ansible venv on a runner
│   ├── dev/                    Local dev helpers (terraform_plan.sh)
│   ├── ops/                    On-call runbook scripts (DNS healthcheck, etc.)
│   └── setup/                  One-shot setup helpers (inventory regen, env import)
├── docs/                       Architecture notes, runbooks, incident logs
├── keys/                       SSH public keys (gitignored — add locally)
└── .github/workflows/          CI/CD pipeline definitions
```

## CI/CD pipeline

| Workflow | Trigger | What it does |
|---|---|---|
| `actionlint.yml` | PR touching `.github/workflows/**` or its version pin | Lints changed GitHub Actions workflows with `actionlint` |
| `ansible-lint.yml` | Push / PR touching `ansible/**`, or reusable call | Runs `ansible-lint` against all playbooks |
| `pr-ready-notify.yml` | PR opened / reopened / ready for review | Notifies when a pull request becomes ready |
| `deploy.yml` | Manual dispatch | Full infrastructure deploy (TF apply + Ansible) |
| `deploy-reusable.yml` | Reusable workflow call | Shared deploy implementation used by `deploy.yml` |
| `gitleaks.yml` | Push / PR | Scans the repo for leaked secrets |
| `maintenance-monitoring.yml` | Manual dispatch | Enables observability agents on selected hosts |
| `maintenance-support-access.yml` | Manual dispatch | Waits for selected hosts and prepares support access |
| `maintenance-upgrades.yml` | Weekly schedule / manual dispatch | Runs apt upgrades and uploads before/after reports |
| `packer-build.yml` | Manual dispatch | Builds and uploads base VM images to Proxmox |
| `packer-validate.yml` | PR touching `infra-images/packer/**` | Runs `packer fmt`, `init`, and `validate` |
| `pre-commit.yml` | Pull request | Enforces fast hygiene, Python formatting/lint, and SSH trust metadata checks on changed files |
| `runner-smoke.yml` | Manual dispatch | Prints basic runner diagnostics |
| `shellcheck.yml` | PR touching `scripts/**` | Runs ShellCheck on changed shell scripts |
| `telegram-notify.yml` | Workflow completion | Sends Telegram notifications for watched workflows |
| `terraform-lint.yml` | Push / PR touching Terraform code | Discovers managed stacks and runs `tflint` per stack plus `checkov` over Terraform |
| `terraform-plan.yml` | Push / PR touching Terraform code | Discovers managed stacks and runs `fmt`, `validate`, and read-only `plan` for each |
| `trivy.yml` | PR touching Ansible image pins; daily schedule; manual dispatch | **Currently skipped** (job gated on repo variable `TRIVY_ENABLED`, unset → skipped; kept, not removed — re-enable by setting `TRIVY_ENABLED=true`). Scans changed images on PRs and the full pinned image inventory daily |

Locally managed tools and workflows that install pinned tools load versions from [`scripts/ci/versions.sh`](scripts/ci/versions.sh); distro-provided utilities remain owned by their workflow.

For the step-by-step flow between local `make` commands, GitHub Actions workflows, the Key Vault fetch action, and the runtime export script, see [docs/ci-workflows.md](docs/ci-workflows.md).
For the exact local and pull-request validation checks, see [docs/validation-checks.md](docs/validation-checks.md).

### Required GitHub Actions variables and Key Vault secrets

See [docs/github-secrets.md](docs/github-secrets.md) for the full reference. GitHub Actions needs repository variables for Azure OIDC; Key Vault stores all runtime secrets used by workflows.

Minimum GitHub repository variables:

- `AZURE_KEYVAULT_NAME`
- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

Minimum Key Vault secrets for the core deploy/plan path:

- `TAILSCALE_OAUTH_CLIENT_ID` + `TAILSCALE_OAUTH_SECRET` — runner-to-LAN connectivity
- `PROXMOX_API_URL`, `PROXMOX_TOKEN_ID`, `PROXMOX_TOKEN_SECRET` — Terraform provider
- `TF_TOKEN_APP_TERRAFORM_IO` — Terraform Cloud remote state
- `TF_VAR_BOOTSTRAP_PASSWORD` — initial VM password
- `TOOMHORVATH_SSH_PRIVATE_KEY` (or `_B64`) + `TOOMHORVATH_SSH_PUBLIC_KEY` — Ansible SSH

Service-specific secrets (e.g. `CLOUDFLARED_TUNNEL_TOKEN`, restic ntfy keys, Telegram bot tokens) carry a per-service `folder` tag in Key Vault and are pulled in via the same fetch.

## First-time local setup

### Prerequisites

- Terraform ≥ 1.6 and a [Terraform Cloud](https://app.terraform.io) account
- The [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`brew install azure-cli` or equivalent), with read access to the Key Vault (`az login`)
- Python 3.11+ for the Make-managed venv (`make bootstrap` installs Ansible, ansible-lint, and Checkov inside it)

### 1. Clone and configure SSH

```bash
git clone https://github.com/<you>/homelab.git
cd homelab
```

If you already hold the fleet keys, `keys/` is derived from them and nothing
further is needed. On a machine that does **not** have them, fetch from Key
Vault rather than copying by hand (this also writes `keys/toomhorvath.pub` and
`keys/runner.pub`, which the bootstrap play reads):

```bash
az login
make ssh-keys
```

See [docs/ssh.md](docs/ssh.md), including the bootstrap loop on a brand-new
machine that has neither the keys nor a clone.

### 2. Bootstrap the local toolchain

```bash
make bootstrap        # creates .venv, installs git hooks, downloads TFLint and Packer
```

### 3. Authenticate to Azure

Local deploy/plan targets read secrets from Key Vault using your ambient Azure
CLI session — no credentials are stored in the repo or `.env`:

```bash
az login
```

The vault name lives in the Makefile (`AZURE_KEYVAULT_NAME`, default
`kv-homelab-prod`) and can be overridden per invocation. Your Azure account
needs the **Key Vault Secrets User** (read) role on the vault.

### 4. Regenerate the Ansible inventory (if IPs change)

The inventory is generated from Terraform variable defaults:

```bash
make gen-inventory
```

## Day-to-day operations

All deploy and plan flows are wrapped by Make targets that fetch secrets from Azure Key Vault at runtime via your `az login` session. No deploy/runtime secrets are stored locally.

### Deploy a single host

```bash
make deploy TARGET=01-media-vm MODE=config      # Configuration only; no infrastructure or package updates
make deploy TARGET=01-media-vm MODE=full        # Terraform + Ansible
make deploy TARGET=01-media-vm MODE=infra       # Terraform only
make deploy-check TARGET=01-media-vm            # dry-run: show diff, change nothing
```


`MODE` is mandatory for deploy commands. There is no implicit default deploy
mode.

The Proxmox SSH identity is pinned in `ansible/ssh_known_hosts`. Guest host
keys are obtained at runtime through trusted `pve`, so VM/LXC rebuilds do not
require manual fingerprint updates; see [docs/ssh.md](docs/ssh.md).

### Deploy all hosts locally

```bash
make deploy-all MODE=config                     # Configure all targets sequentially
make deploy-all MODE=full                        # Full deploy of all targets
```

### Plan Terraform changes (read-only)

```bash
make terraform-plan TARGET=01-media-vm          # one stack
make terraform-plan-all                         # every stack
```

Both require Tailscale to be connected so the local runner can reach the Proxmox API.

### Maintenance and discovery

```bash
make update-all       # apt update+upgrade across every host, log to logs/
make ping             # SSH reachability check
make status           # uptime, load, disk, memory per host
make facts TARGET=X   # dump ansible facts for one host

make hosts            # list deployable hosts
make roles            # list ansible roles
make version          # show pinned tool versions
```

### Lint locally before opening a PR

```bash
make ci               # mirrors non-deploying GitHub Actions validation
```

`make ci` intentionally performs a full local baseline check before opening a
PR. Pull-request jobs restrict file-local checks to changed files, while
Ansible, Packer, Terraform, Checkov, and secret scanning validate their full
affected scope where shared inputs or security coverage require it. A change
to a checker configuration or its pin also causes that checker to rerun its
full baseline.

## Storage model

The Proxmox host owns all storage. Guests mount shares in two ways:

**VirtIO-FS (for VMs):** Zero-copy filesystem sharing via Proxmox Directory
Mappings. Used by all three VMs — `01-media-vm` (appdata + media),
`01-unifi-vm` (appdata), and `01-myapps-vm`, which mounts the same share at
`/srv/backup-share` because `/srv/appdata` there is local disk holding live
state.

**LXC bind mounts:** Host paths bound directly into container filesystems. Used
by `01-torrent-lxc` (3), `01-backup-lxc` (2), and one each for
`01-tailscale-lxc` (node identity state), `01-observability-lxc` and
`01-code-lxc`. `01-edge-lxc`, `01-dns-lxc` and `01-reverse-proxy-lxc` have none.

**SQLite never lives on the share.** VirtIO-FS is fine for regular files, but
opening a SQLite database on it fails outright with `disk I/O error`. Both
Docker hosts keep live databases on local ext4 and mirror *snapshots* to the
share, where restic sweeps them offsite — see
[docs/compose-vm.md](docs/compose-vm.md).

Host mount points:
- `/srv/appdata` — application data (SSD)
- `/srv/media` — mergerfs pool across `/mnt/d8`, `/mnt/d16`, `/mnt/d24`
- `/srv/staging-ssd` — torrent incomplete downloads (SATA SSD, `sda1`; the NVMe holds the `pve` VG)

## Adding a new service

1. **New LXC/VM** — copy the most similar stack in `infra-proxmox/terraform/`, update `variables.tf` with your IPs/names, add the resource via `module "lxc"` or `module "vm"` in `main.tf`, and add an `outputs.tf`.

2. **Regenerate inventory** — `make gen-inventory`

3. **Write an Ansible playbook** — add `ansible/playbooks/services/01-<name>.yml` and a corresponding `ansible/host_vars/01-<name>/vars.yml`.

4. **Wire secrets through Key Vault** — add any new secrets to the vault with the appropriate `folder`/`envvar` tags (`az keyvault secret set --vault-name kv-homelab-prod --name <folder>-<slug> --value <v> --tags folder=<folder> envvar=<ENV_NAME>`) and pass them into Ansible via `extra_vars` in [`scripts/ci/run_ansible.sh`](scripts/ci/run_ansible.sh) (mirroring the `CLOUDFLARED_TUNNEL_TOKEN` pattern).

5. **Register in CI** — add the stack to `scripts/ci/targets.sh` and add manual inputs in `deploy.yml` and the maintenance workflows. A Terraform stack with `backend.tf` is discovered automatically by the plan/lint workflows.

## Key design decisions

- **Terraform Cloud for remote state** — each Terraform stack has its own workspace; no local `.tfstate` files in git.
- **Shared Terraform modules** — `modules/proxmox-lxc` and `modules/proxmox-vm` hold all resource logic; stacks are thin wrappers of ≈30 lines.
- **Static IPs** — all hosts use fixed IPs (DHCP reservations + cloud-init), making inventory generation trivial.
- **No NFS** — storage shared into guests via VirtIO-FS or LXC bind mounts to avoid NFS latency and caching issues with Plex/SQLite.
- **DNS-first boot order** — `01-dns-lxc` starts with `startup_order = 10`; all other hosts resolve names by the time they come up.
- **Azure Key Vault as the single source of runtime secrets** — both local Make targets (`az login`) and GitHub Actions (OIDC) pull from the same vault; there is no Ansible Vault, no in-cluster secrets service, and no secrets in git.

## Further reading

- [docs/platform.md](docs/platform.md) — detailed architecture and storage model
- [docs/ci-workflows.md](docs/ci-workflows.md) — local Make → GitHub Actions → Azure Key Vault flow
- [docs/github-secrets.md](docs/github-secrets.md) — all CI secrets explained
- [docs/terraform.md](docs/terraform.md) — Terraform Cloud setup and workspace config
- [docs/ansible.md](docs/ansible.md) — Ansible conventions used in this repo
- [docs/ssh.md](docs/ssh.md) — SSH key setup and access patterns
- [docs/backup-lxc.md](docs/backup-lxc.md) — backup strategy and Restic configuration
