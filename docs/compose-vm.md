# Media VM: Docker + Compose (VirtIO-FS)

This runbook provisions `01-media-vm` (Ubuntu VM) for the homelab Docker Compose stack.

**Storage model:** the Proxmox host owns disks and exports directories into the VM via **VirtIO-FS**
(Proxmox Directory Mappings). The VM does **not** mount disks, run mergerfs, or use NFS.

## 0) Prereqs (on the Proxmox host)
- `/srv/appdata` exists and contains app configs
- `/srv/media` exists and contains `downloads/`, `movies/`, `series/` (or let Ansible create them inside the share)

## 1) Terraform: create/update the VM

Go through the Makefile, not `terraform` directly — the wrapper injects Key
Vault secrets and enforces the replacement guard below:

```bash
make terraform-plan TARGET=01-media-vm
make deploy TARGET=01-media-vm MODE=infra
```

Defaults live in `infra-proxmox/terraform/01-media-vm/variables.tf` (vmid 150,
`ip_address` 192.168.1.70/24, `enable_virtiofs_shares = true`,
`virtiofs_appdata_host_path = /srv/appdata`, `virtiofs_media_host_path =
/srv/media`); a `terraform.tfvars` is not required.

**Replacement is gated, deliberately.** `scripts/ci/terraform_apply.sh` refuses
any apply that would DELETE this VM unless a verified stopped-state manifest
under 6 hours old is present — its application state is on the VM's root disk,
not the share. The only supported path is:

```bash
make rebuild-media MEDIA_REBUILD_CONFIRM=true
```

which quiesces the compose stack, mirrors local state, validates the Plex SQLite
restore inputs, takes an offsite restic snapshot, then replaces the VM and
restores services. `MEDIA_REBUILD_CONFIRM=true` is required in a non-interactive
shell; without it the script prompts and would hang.

## 2) Ansible: mount VirtIO-FS + deploy compose

```bash
make deploy TARGET=01-media-vm MODE=config
```

Notes:
- The playbook mounts the VirtIO-FS shares at `/srv/appdata` and `/srv/media`.
- `ansible/roles/media_stack/templates/homelab-compose.yml.j2` is rendered to `/opt/homelab/compose.yml`.
- Kometa support is wired in but disabled by default. Set `kometa_enabled: true`, then provide the Plex token and TMDb API key either in `ansible/host_vars/01-media-vm/vars.yml` or via GitHub Secrets exposed as `KOMETA_PLEX_TOKEN` and `KOMETA_TMDB_APIKEY`, and adjust `kometa_libraries` before redeploying.
- The media playbook does not force a `docker compose pull` by default because images are pinned; use `-e homelab_update_images=true` only when you intentionally want to refresh unchanged tags.
- To stop managing the compose file from Ansible: `-e compose_manage_file=false`.

## Local state vs the share

Not everything lives on VirtIO-FS, and the split is load-bearing:

- **`/var/lib/homelab` (local ext4)** holds SQLite-backed app state — the `*arr`
  configs, Plex databases, codecs and cache. VirtIO-FS is fine for regular files,
  but SQLite write/locking semantics break on it: opening a database on the share
  fails outright with `disk I/O error`, read-only included.
- **`/srv/appdata` (the share)** receives nightly *snapshots* of that state via
  `homelab-local-state-backup.service`, where `01-backup-lxc`'s restic run sweeps
  them to B2.

`homelab_local_state_paths` in `ansible/host_vars/01-media-vm/vars.yml` declares
each entry; the mirror script and its units come from the shared
`roles/local_state_backup`. On a rebuilt VM the same list drives the restore, and
`media_stack` verifies each restored database with `PRAGMA quick_check` before
writing the seed marker.

## 3) Manage the stack

```bash
sudo systemctl enable --now homelab-compose
sudo systemctl restart homelab-compose
sudo systemctl status homelab-compose
```

## Troubleshooting

Verify mounts inside the VM:
```bash
findmnt /srv/appdata
findmnt /srv/media
```

If mounts are missing, check:
- Proxmox VM hardware includes the VirtIO-FS devices (Directory Mappings)
- the mapping names/tags match what Ansible mounts (`homelab-appdata`, `homelab-media`)
