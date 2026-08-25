# Proxmox Boot & Shutdown Order (Host-Owned Storage)

**Scope:** Autostart (`onboot`) + sequencing (`startup`) for Proxmox node `pve`.

**Why:** When storage was provided by a VM/NFS, apps could start on missing mounts and implode. The current model is **host-owned storage** shared into guests (VirtIO-FS to VMs, bind mounts to LXCs). Sequencing still matters for DNS and ingress.

## Boot Order (Autostart)

Dependency-first, then contention-spaced. Verified live on `pve` 2026-08-19.

| Order | ID  | Name                   | Type | Onboot | Up  | Down | Notes |
|------:|----:|------------------------|------|:------:|----:|-----:|-------|
| 10    | 161 | `01-dns-lxc`            | LXC  | yes    | 10s |  60s | Internal DNS first; stops last |
| 15    | 165 | `01-tailscale-lxc`      | LXC  | yes    |  5s |  30s | Break-glass remote access (see below) |
| 20    | 162 | `01-reverse-proxy-lxc`  | LXC  | yes    | 10s |  30s | Traefik (LAN ingress) |
| 25    | 160 | `01-edge-lxc`           | LXC  | yes    |  5s |  30s | Cloudflare tunnel; depends on Traefik |
| 28    | 174 | `01-observability-lxc`  | LXC  | yes    |  5s |  30s | Before the VMs, so it observes their startup |
| 35    | 150 | `01-media-vm`           | VM   | yes    | 20s | 120s | Docker/Compose stack |
| 40    | 152 | `01-unifi-vm`           | VM   | yes    | 20s |  — | UniFi OS Server (Java + Mongo). **No explicit `down`** — see below |
| 42    | 151 | `01-myapps-vm`          | VM   | yes    | 20s | 120s | Docker/Compose stack |
| 50    | 171 | `01-torrent-lxc`        | LXC  | yes    |  0s |  60s | Last autostart; `down` allows resume-data flush |
| 55    | 176 | `01-code-lxc`           | LXC  | yes    |  0s |  30s | code-server; state on the appdata bind mount |
| 65    | 173 | `01-backup-lxc`         | LXC  | **no** |  0s |  60s | Manual start; avoids a job firing mid-boot |

Template `901 tpl-ubuntu-2604-base` never autostarts.

Cumulative autostart delay: **~95s** to issue the last start (10+5+10+5+5+20+20+20);
allow ~2 min for services inside the guests to settle.

> **Known exception to Rule 3 below:** `01-unifi-vm` has no `startup_down_delay`
> in `infra-proxmox/terraform/01-unifi-vm/main.tf`, so it falls back to Proxmox's
> 180s default — on the guest the table itself calls a "slow clean stop". Verified
> live 2026-08-25. Either set it or delete this note; do not leave the table
> claiming a value that is not set.

### Design Rules

These three rules explain every number in the table. Apply them when adding a
guest rather than copying a neighbour's values.

1. **`up=S` gates the *next* guest, not this one.** It means "wait S seconds
   before starting the next order" — so a delay only earns its keep when
   something later depends on this guest being *ready*. The last guest in the
   sequence gets `up=0`; its delay would gate nothing.
2. **Only two real dependencies exist here:** DNS before everything, and
   Traefik (162) before the Cloudflare tunnel (160). All other spacing is
   disk-I/O contention management, which is why it is concentrated on the
   three VMs (~18 GB combined) and near-zero on small LXCs.
3. **`down=S` is a force-stop deadline.** Unset means Proxmox falls back to its
   default (180s per VM) — three hanging VMs can stall a node shutdown for
   ~9 minutes, which is how a power event turns into an unclean shutdown. Set
   it explicitly, generously for stateful guests (UniFi, torrent), tightly for
   stateless ones.

### Why Tailscale Boots Early

`pve` is an ASRock Z790M-ITX WiFi — a consumer board with **no IPMI/BMC**.
Tailscale (165) is therefore the only remote path into the node when something
goes wrong. It sits at order 15, ahead of ingress and all VMs, so a boot that
wedges in a later stage is still reachable without a physical trip. It is
placed after DNS because it wants working resolution at startup.

### Shutdown Sequencing

Proxmox walks the order in **reverse**, so the table above already yields the
correct shutdown: utilities and VMs first, DNS last. `startup` order applies to
any *running* guest regardless of `onboot`, which is why 173 keeps an
order despite starting manually — it guarantees they stop first.

## Example Proxmox Configuration Commands

```bash
# LXCs
pct set 161 --onboot 1 --startup order=10,up=10,down=60   # DNS
pct set 165 --onboot 1 --startup order=15,up=5,down=30    # tailscale (break-glass)
pct set 162 --onboot 1 --startup order=20,up=10,down=30   # reverse proxy
pct set 160 --onboot 1 --startup order=25,up=5,down=30    # edge/tunnel
pct set 174 --onboot 1 --startup order=28,up=5,down=30    # observability
pct set 171 --onboot 1 --startup order=50,up=0,down=60    # torrent
pct set 176 --onboot 1 --startup order=55,up=0,down=30    # code-server
pct set 173 --onboot 0 --startup order=65,up=0,down=60    # backup (manual)

# VMs
qm set 152 --onboot 1 --startup order=30,up=20,down=120   # unifi
qm set 150 --onboot 1 --startup order=35,up=20,down=120   # media
qm set 151 --onboot 1 --startup order=40,up=15,down=120   # myapps
```

## Reading A Post-Reboot State

Guests appear `stopped` for minutes after a reboot **by design** — the delays
above are cumulative. Judge a stopped guest against its order and the node's
uptime before calling it a failure, and check `systemctl --failed` on the node.
Nothing is genuinely late until roughly 2 minutes past its scheduled start.

## Mount Guards

Implemented 2026-08-19. Script: [`scripts/ops/pve-mount-guard.sh`](../scripts/ops/pve-mount-guard.sh),
deployed to `local:snippets/mount-guard.sh` on `pve`.

**Why this is mandatory, not optional.** Every storage line in `/etc/fstab`
uses `nofail` — correct at the host level, since a dead disk should not drop
the node into an emergency shell. But `nofail` is exactly what lets the node
boot with `/srv/appdata` or a media disk missing. Without a guard the guest
starts anyway and:

- writes land on the **root filesystem**, filling it, with the state hidden the
  moment the real volume mounts again; and
- `/srv/media` appears empty or partial, so **Plex scans a degraded library and
  removes titles from it** — losing watch history, collections and metadata,
  which do not come back when the disk does.

Host-level `nofail` and this fail-closed guest-level guard are a matched pair.
Do not remove one without the other.

### Guarded Guests And Their Required Mounts

| Guest | `/srv/appdata` | `/srv/media` + branches | `/srv/staging-ssd` | `/mnt/d16` |
|-------|:--------------:|:-----------------------:|:------------------:|:----------:|
| 150 `01-media-vm`         | ✓ | ✓ |   |   |
| 152 `01-unifi-vm`         | ✓ |   |   |   |
| 165 `01-tailscale-lxc`    | ✓ |   |   |   |
| 171 `01-torrent-lxc`      | ✓ | ✓ | ✓ |   |
| 173 `01-backup-lxc`       | ✓ |   |   | ✓ |
| 174 `01-observability-lxc`| ✓ |   |   |   |
| 176 `01-code-lxc`         | ✓ |   |   |   |

Derived from the virtiofs dir mappings (`homelab-appdata` → `/srv/appdata`,
`homelab-media` → `/srv/media`, both Terraform-managed) and the LXC `mp` entries.
160, 161 and 162 have no host-storage dependency and are deliberately **not**
guarded — the script passes unknown VMIDs through untouched.

**151 `01-myapps-vm` is the exception worth understanding.** It *does* mount
`homelab-appdata`, but at `/srv/backup-share`, and only as a backup target: its
live state sits on the guest's own local disk. A missing share therefore cannot
corrupt anything there, and guarding it would take digest, garmin, withings and
jobs-refresh offline over a mount they do not need in order to run. Instead the
consequence is made loud rather than silent — `digest-state-backup` exits
non-zero when `/srv/backup-share` is not a mountpoint, and its
`OnFailure=digest-backup-notify.service` fires. Reviewed and chosen deliberately
2026-08-25; it is not an oversight.

### The mergerfs Subtlety

`/srv/media` is mergerfs over `/mnt/d8:/mnt/d16:/mnt/d24`. **mergerfs mounts
successfully with only some branches present**, so "is `/srv/media` mounted?"
does not tell you the library is whole. The guard therefore verifies each
branch individually and fails closed if any one is missing. A single dead disk
takes the media stack offline until you intervene — deliberate, because a
degraded Plex scan is destructive and an offline Plex is not.

The guard also rejects a **read-only** mount (ext4 remounts `ro` on error),
which otherwise produces confusing application-level failures rather than a
clean stop.

### Behaviour

Runs on `pre-start` only; a non-zero exit makes Proxmox abort the start. There
is no retry loop — `pve-guests.service` is ordered after `local-fs.target`, so
mounts are already settled (and `nofail` entries carry
`x-systemd.device-timeout`) by the time the guard runs. An abort means a human
should look, not that the system should try again.

### Install / Reinstall

```bash
sudo install -m 0755 scripts/ops/pve-mount-guard.sh /var/lib/vz/snippets/mount-guard.sh
sudo pvesm set local --content vztmpl,iso,backup,import,snippets   # snippets must be enabled

# LXCs only. Attaching the guard to the two VMs is Terraform's job as of
# 2026-08-25 (#818): both stacks declare
#   hook_script_file_id = var.mount_guard_hook_script_file_id
# defaulting to this same shared snippet. Running `qm set` by hand still works,
# but a VM REPLACEMENT would come up unguarded without the Terraform
# declaration -- the attachment does not survive a destroy/create, only an
# in-place apply.
for id in 165 171 173 174 176; do sudo pct set "$id" --hookscript local:snippets/mount-guard.sh; done
```

The LXC module carries `ignore_changes = [hook_script_file_id]`, because the
container resource -- unlike the VM resource -- actively plans to clear the
attribute. That is why containers keep a hand-made attachment across applies and
VMs need it declared.

### Testing It

The guard supports a `GUARD_REQUIRE_OVERRIDE` env var, used for testing only
and never set in production:

```bash
G=/var/lib/vz/snippets/mount-guard.sh
sudo bash $G 150 pre-start                                   # expect exit 0
sudo bash $G 150 post-start                                  # expect exit 0 (wrong phase, no-op)
sudo bash $G 151 pre-start                                   # expect exit 0 (unguarded VMID)
sudo GUARD_REQUIRE_OVERRIDE=/nonexistent bash $G 150 pre-start  # expect exit 1
```

### When The Guard Fires

Do **not** bypass it. Find the missing mount, fix it, then start the guest:

```bash
findmnt -no SOURCE,TARGET,FSTYPE /srv/appdata /srv/media /mnt/d8 /mnt/d16 /mnt/d24
```

Guard output appears in the guest's start task log in the Proxmox UI.

## Verification Commands

Run these commands in a root shell on `pve`. The summary block displays every
configured VM and LXC, sorted by startup order; entries without an explicit
order appear at the end with order `9999`.

```bash
tmp="$(mktemp)"

qm list | awk 'NR>1 { print $1 }' | while read -r id; do
  cfg="$(qm config "${id}" 2>/dev/null)"
  name="$(awk -F': ' '$1 == "name" { print $2 }' <<<"${cfg}")"
  onboot="$(awk -F': ' '$1 == "onboot" { print $2 }' <<<"${cfg}")"
  startup="$(awk -F': ' '$1 == "startup" { print $2 }' <<<"${cfg}")"
  order="$(sed -n 's/.*order=\([0-9]\+\).*/\1/p' <<<"${startup}")"
  up="$(sed -n 's/.*up=\([0-9]\+\).*/\1/p' <<<"${startup}")"
  down="$(sed -n 's/.*down=\([0-9]\+\).*/\1/p' <<<"${startup}")"
  printf 'VM\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${id}" "${name}" "${onboot:-0}" "${order:-9999}" "${up:-0}" "${down:-0}" >>"${tmp}"
done

pct list | awk 'NR>1 { print $1 }' | while read -r id; do
  cfg="$(pct config "${id}" 2>/dev/null)"
  name="$(awk -F': ' '$1 == "hostname" { print $2 }' <<<"${cfg}")"
  onboot="$(awk -F': ' '$1 == "onboot" { print $2 }' <<<"${cfg}")"
  startup="$(awk -F': ' '$1 == "startup" { print $2 }' <<<"${cfg}")"
  order="$(sed -n 's/.*order=\([0-9]\+\).*/\1/p' <<<"${startup}")"
  up="$(sed -n 's/.*up=\([0-9]\+\).*/\1/p' <<<"${startup}")"
  down="$(sed -n 's/.*down=\([0-9]\+\).*/\1/p' <<<"${startup}")"
  printf 'CT\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${id}" "${name}" "${onboot:-0}" "${order:-9999}" "${up:-0}" "${down:-0}" >>"${tmp}"
done

{
  printf 'TYPE\tID\tNAME\tONBOOT\tORDER\tUP_s\tDOWN_s\n'
  sort -k5,5n -k1,1 -k2,2n "${tmp}"
} | column -t -s $'\t'
rm -f "${tmp}"

# Storage mount guard verification - all 7 guarded guests must print a hookscript:
for id in 150 152; do qm  config "$id" | grep -E 'hookscript|startup'; done
for id in 165 171 173 174 176; do pct config "$id" | grep -E 'hookscript|startup'; done

# Underlying mounts:
findmnt -no SOURCE,TARGET,FSTYPE /srv/appdata /srv/media /mnt/d8 /mnt/d16 /mnt/d24
```
