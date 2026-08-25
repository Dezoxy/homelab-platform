# Backup LXC Time Machine Share

`01-backup-lxc` now serves an authenticated SMB share configured as a native Time Machine target for macOS backups.

## Endpoint

- SMB URL: `smb://01-backup-lxc.home.arpa/macbook-backup`
- Fallback host: `192.168.1.73`
- Share path inside the LXC: `/srv/appdata/macbook-backup`
- Host backing path: `/mnt/d16/backups/macbook-backup`
- SMB login: `tmuser`
- Time Machine mode: enabled via Samba `fruit:time machine = yes`
- Reported Time Machine size cap: `500G`

This is still a server-side target only. The repo does not automate the MacBook-side backup workflow.

## Offsite backup targets

- Primary offsite target: Backblaze B2 via `RESTIC_APPDATA_REPOSITORY`
- Secondary AWS S3 target is currently commented out/disabled
- The timer run writes to B2 only
- Retention applied to the B2 repository: **7 daily, 4 weekly, 6 monthly**
  (`restic_appdata_keep_daily` / `_weekly` / `_monthly`, `roles/restic_backup/defaults`)

### What reaches this repository from other guests

`/srv/appdata` on the host is the VirtIO-FS share, so anything a guest mirrors
there is swept from here without needing its own offsite job:

- `01-media-vm` mirrors `/var/lib/homelab` (SQLite app state) via
  `homelab-local-state-backup.service`
- `01-myapps-vm` mirrors `garmin-health`, `withings-sync` and the jobs-refresh
  deploy keys the same way, plus dated `myapps-digest/state-*.db` snapshots
  (14 kept, pruned by `digest-state-backup`)

Both keep their *live* SQLite on local ext4 and copy snapshots across, because
SQLite cannot be opened on the share at all — see `docs/compose-vm.md`.

## Deploy

Store the required backup and Samba settings in Azure Key Vault, then reconcile the
service through the supported local deployment wrapper:

```bash
make deploy TARGET=01-backup-lxc MODE=config
```

## Notes

- The share is **excluded from the restic offsite backup** (`/srv/appdata/macbook-backup` in
  `restic_appdata_excludes`). It is mounted inside `/srv/appdata` only because that is where the
  container bind mount lands (`backup_time_machine_mount_path`); the data itself lives on mergerfs
  at `/mnt/d16/backups/macbook-backup`, not on the appdata volume. Do not remove that exclude line:
  a Time Machine sparsebundle rewrites its band files on every run, so it dedupes badly and added
  ~260 GiB of near-incompressible churn to the B2 repository before it was excluded on 2026-07-04.
  Time Machine is itself the backup; it does not need a second offsite copy.
- The backup script currently runs the B2 target only; the AWS secondary target is commented out.
- Disposable `*arr` SQLite log databases (`logs.db*`) are excluded from restic because their transient WAL/SHM sidecars can appear and disappear during live backups.
- Also excluded, for the same "reproducible or disposable" reason: Plex `Cache/`
  and `Codecs/`, `plex-transcode`, the Prometheus/Loki/Tempo data directories
  (config and Grafana's own database are kept), and `code/code-server/extensions`
  — ~1.6 GB that `roles/code_server` reinstalls from the declared Open VSX ids
  and the `../vsix` directory, which *is* backed up.
- The playbook requires `/srv/appdata` to be a real mountpoint before either restic or `smbd` will run against it.
- Guest access is disabled; `tmuser` is the expected SMB login for the share.
- Avahi is installed so the Time Machine share can be advertised on the LAN via Bonjour/mDNS.
- The size cap is reported through `fruit:time machine max size = 500G`. Samba documents this as an approximation based on the sparsebundle contents, so this share should remain dedicated to Time Machine data.

## Restore

### List snapshots

```bash
# B2 (primary)
restic -r "$RESTIC_APPDATA_REPOSITORY" \
  -p <(echo "$RESTIC_APPDATA_PASSWORD") \
  snapshots

# AWS S3 (secondary) is currently disabled.
# restic -r "$AWS_APPDATA_BACKUP_PATH" \
#   -p <(echo "$RESTIC_APPDATA_PASSWORD") \
#   snapshots
```

### Restore latest to a staging path

```bash
restic -r "$RESTIC_APPDATA_REPOSITORY" \
  -p <(echo "$RESTIC_APPDATA_PASSWORD") \
  restore latest --target /tmp/restore-staging
```

### Restore a specific snapshot

```bash
# Replace <snapshot-id> with the short ID from `snapshots` output
restic -r "$RESTIC_APPDATA_REPOSITORY" \
  -p <(echo "$RESTIC_APPDATA_PASSWORD") \
  restore <snapshot-id> --target /tmp/restore-staging
```

### Restore a single path from a snapshot

```bash
restic -r "$RESTIC_APPDATA_REPOSITORY" \
  -p <(echo "$RESTIC_APPDATA_PASSWORD") \
  restore latest --target /tmp/restore-staging \
  --include /srv/appdata/sonarr
```

### Verify repository integrity

```bash
restic -r "$RESTIC_APPDATA_REPOSITORY" \
  -p <(echo "$RESTIC_APPDATA_PASSWORD") \
  check
```

The env vars (`RESTIC_APPDATA_REPOSITORY`, `RESTIC_APPDATA_PASSWORD`, `B2_S3_KEY_ID`, `B2_S3_APPLICATION_KEY`) must be set before running any restic command. CI runtime values are stored in Azure Key Vault — see [github-secrets.md](github-secrets.md) for the names.
