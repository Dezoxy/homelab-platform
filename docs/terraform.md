# Terraform Provisioning

## Prerequisites

**Proxmox host reachable** at `https://192.168.1.239:8006`. The Terraform provider connects with either username/password or an API token — see `terraform.tfvars.example` in each module for the fields.

**Ubuntu template present** on Proxmox storage. The catalog pins
`ubuntu-26.04-standard_26.04-1_amd64.tar.zst` for LXCs and template VMID 901
(`tpl-ubuntu-2604-base`) for VMs — see [base-images.md](base-images.md).

No manual `pveam download` step is needed: `make deploy` runs
`scripts/ci/ensure_target_image.sh` before Terraform for any mode that includes
infrastructure (`Makefile:233`, `scripts/ci/run_ansible.sh:77`), which downloads
a missing LXC archive or builds a missing VM template with Packer. To do it on
its own:

```bash
make ensure-image IMAGE=ubuntu-2604-vm-v1
```

**Terraform Cloud** — the backend is configured in each module's `backend.tf`. Set `TF_TOKEN_app_terraform_io` (or log in via `terraform login`) before running `init`.

## tfvars

Each module has a `terraform.tfvars.example`, but a `terraform.tfvars` is **not
required** for normal use: the defaults in each module's `variables.tf` already
match the live fleet, and the deploy wrapper injects credentials from Key Vault.
Copy it only when overriding something:

```bash
cp -n terraform.tfvars.example terraform.tfvars
```

Key variables common to all modules:

| Variable | What to set |
|----------|-------------|
| `proxmox_url` | `https://192.168.1.239:8006/api2/json` |
| `proxmox_node` | `pve` |
| `proxmox_username` | `root@pam` (or token ID) |
| `proxmox_password` | root password (or leave blank if using token) |

Each module also has per-resource variables (VMID, IP, disk size, hostname) — the defaults in the example file match the live inventory. Only change them if you're rebuilding with a different VMID or IP.

## State

State is stored in Terraform Cloud. `terraform init` pulls the remote backend config. If you need to inspect or manipulate state manually:

```bash
terraform state list
terraform state show <resource>
```

## Provisioning order

Do not run `terraform` directly per module. The Makefile wrapper injects Key
Vault credentials, resolves the catalog pin, and enforces the media-VM
replacement guard:

```bash
make terraform-plan TARGET=01-dns-lxc     # plan one stack
make terraform-plan-all                   # plan every stack
make deploy TARGET=01-dns-lxc MODE=infra  # apply infrastructure only
make deploy TARGET=01-dns-lxc MODE=full   # infrastructure + Ansible
```

Eleven stacks exist: `01-media-vm`, `01-myapps-vm`, `01-unifi-vm`,
`01-backup-lxc`, `01-code-lxc`, `01-dns-lxc`, `01-edge-lxc`,
`01-observability-lxc`, `01-reverse-proxy-lxc`, `01-tailscale-lxc`,
`01-torrent-lxc`.

Order only matters when building from nothing, and the real dependency is DNS
before anything that must resolve names, then Traefik before the Cloudflare
tunnel: `01-dns-lxc` → `01-reverse-proxy-lxc` → `01-edge-lxc` → everything else.
(Boot-time sequencing is a separate concern — see
[proxmox-boot-shutdown-order.md](proxmox-boot-shutdown-order.md).)

**`01-media-vm` is gated.** Any apply that would delete VM 150 is refused
without a verified stopped-state manifest; use
`make rebuild-media MEDIA_REBUILD_CONFIRM=true`. See [compose-vm.md](compose-vm.md).

After Terraform creates the VMs/LXCs, run Ansible to configure them — see [ansible.md](ansible.md).
