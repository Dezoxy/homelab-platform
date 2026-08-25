# UniFi OS Server — self-hosted controller for a remote site

Runbook for `01-unifi-vm` (VMID 152, `192.168.1.75`), which manages three access
points installed at a **family house on a different network**.

> **Migrated 2026-08-19.** This ran as `01-unifi-lxc` (VMID 166, `192.168.1.8`)
> — the LinuxServer UniFi Network Application plus its own MongoDB, on Docker in
> an LXC — until Ubiquiti made UniFi OS Server the supported self-hosting path.
> That guest is destroyed; its Terraform stack, playbook and `unifi` role were
> archived under `retired/` and removed from the working tree on 2026-08-22 —
> recover them from git history if ever needed.
>
> Everything below about the *problem* — that adoption is a pull, that TCP 8080
> is the only port that matters, that controller downtime is not WiFi downtime —
> is unchanged and still governs the design. What changed is the host and the
> packaging. Sections describing the LXC's Docker/MongoDB stack are kept for
> history and marked; they do not describe the running system.
>
> Port 8080 is identical on both, which is why the cutover was a router-forward
> change and needed no work at the family house.

## Why this is not just "install a controller"

UniFi adoption is a **pull**, not a push. The AP opens an HTTP POST to
`http://<controller>:8080/inform` on a heartbeat; the controller never dials the
AP. So the entire remote-management problem reduces to one question:

> Can the AP open TCP 8080 to the controller?

Two consequences worth internalising before touching anything:

- **There is no Ubiquiti relay for this.** `unifi.ui.com` / Site Manager relays
  *your browser* to the controller. It does **not** relay device traffic —
  Ubiquiti's architecture keeps the control plane local, and devices always talk
  directly to their controller. The only products that avoid open ports are
  UniFi OS consoles (UDM/UCG/Cloud Key), and that works precisely because the
  controller sits on the same LAN as the APs.
- **Controller downtime is not WiFi downtime.** APs cache their provisioned
  config and keep serving clients when the controller is unreachable. You lose
  config changes, firmware updates and stats — not the network. This is why
  running the controller 200 km from the APs is acceptable at all.

## Architecture

```
Family house LAN                        Home LAN (192.168.1.0/24)
┌───────────────┐                       ┌──────────────────────────┐
│ U7 Pro  ×3    │  inform  TCP 8080     │ 01-unifi-vm  .75         │
│               │  STUN    UDP 3478     │  └─ UniFi OS Server      │
│               │ ────────────────────▶ │     (rootless Podman)    │
└───────────────┘  direct to WAN IP,    └──────────────────────────┘
                   router port-forward
                   ▲
                   unifi-inform.example.net  (grey-cloud A, DDNS-updated)
```

Ports published by the compose stack:

| Port | Proto | Needed by remote APs? | Purpose |
|---|---|---|---|
| 8080 | tcp | **yes — mandatory** | device inform |
| 8443 | tcp | no | admin UI (HTTPS, self-signed) |
| 3478 | udp | yes — forwarded | STUN — lets the controller push config immediately instead of on the next inform tick |
| 10001 | udp | no | L2 discovery — only used for on-LAN staging adoption |

Both required ports are plain router forwards to `192.168.1.75`. The admin UI is
**not** forwarded: reach it on the LAN at `https://192.168.1.75:11443/`, or
through `unifi.ui.com` once Remote Access is enabled.

The LAN split-horizon rewrite for `unifi-inform.example.net` also points at
`192.168.1.75` (see [dns-rewrites.md](dns-rewrites.md)), and the Cloudflare DDNS
updater that keeps the public record current now runs on `01-unifi-vm` — it
moved off the LXC before that guest was destroyed, since losing it would strand
the APs at the next WAN IP change.

> The sections numbered 1–3 below provision the **retired** LXC: the Proxmox
> bind mount, the MongoDB credentials and the Docker Compose stack. They are
> kept for history. The current host is built by
> `infra-proxmox/terraform/01-unifi-vm` and `ansible/roles/unifi_os_server`.

## 1) Provision the LXC

Preview the stack — this repo has no local `terraform apply` on purpose
(`make terraform-plan` is documented "Read-only — never applies"); the apply
runs through the `deploy.yml` workflow with `target_01_unifi_lxc`:

```bash
make terraform-plan TARGET=01-unifi-vm
```

The bind mount must exist on the Proxmox host first, with ownership matching
what runs inside the container. This guest is **privileged** (like every other
bind-mounted guest here), so host and container UIDs are 1:1 — MongoDB's `999`
and the LinuxServer container's `1000` mean the same thing on both sides:

```bash
mkdir -p /srv/appdata/unifi/config /srv/appdata/unifi/mongo
chown 1000:1000 /srv/appdata/unifi/config
chown  999:999  /srv/appdata/unifi/mongo
chmod 0750 /srv/appdata/unifi/config /srv/appdata/unifi/mongo
```

`nesting` and `keyctl` are both required to run Docker in an LXC. Proxmox only
lets `root@pam` change feature flags, so if you applied with a non-root API
token, set them from the PVE shell and restart the container:

```bash
pct set 166 -features nesting=1,keyctl=1
```

Without `keyctl`, MongoDB fails at startup on kernel keyring syscalls — it looks
like a permissions bug, not a container config bug.

## 2) Store the MongoDB credentials

Two secrets in Key Vault, folder `unifi`:

| Slug | envvar |
|---|---|
| `unifi-mongo-password` | `UNIFI_MONGO_PASSWORD` |
| `unifi-mongo-root-password` | `UNIFI_MONGO_ROOT_PASSWORD` |

> These are read on **first start only**. MongoDB persists the hashed user into
> the data directory, so changing the Key Vault value later is a no-op — rotation
> means `db.changeUserPassword()` inside the `unifi-db` container, then updating
> the secret.

## 3) Deploy

```bash
make deploy TARGET=01-unifi-vm MODE=config
```

Then reach the UI at `https://192.168.1.75:8443` (self-signed cert warning is
expected) and complete first-run setup.

### 3a) Link your existing Ubiquiti (UI) account

A self-hosted Network Server **can** be linked to an existing UI account — you
do not need a separate local-only identity. Enable it at:

**Settings → System → Administration → Remote Access**

(On a UniFi OS console this is on by default; self-hosted Network Servers keep
it under Administration, which is why guides written for a Cloud Key point you
somewhere else.)

What linking the account gets you:

| ✅ Gives you | ❌ Does *not* give you |
|---|---|
| Browser access from anywhere via `unifi.ui.com` / Site Manager — no need to tunnel 8443 | Any relay for device inform traffic |
| MFA on controller login | Any way for the remote APs to find the controller |
| Push notifications and cloud backup | A substitute for the Override Inform Host step |

This is why 8443 is never forwarded: your account already solves *your* remote
access. It does nothing for the APs' remote access, which is a separate problem
with a separate answer (step 4).

> **This costs nothing.** Do not confuse two products that share the
> `unifi.ui.com` portal:
>
> | | What it is | Cost |
> |---|---|---|
> | **Site Manager / Remote Access** | Manage a controller *you* host, from anywhere. What this runbook uses. | **Free** — Ubiquiti markets it as license-free |
> | **Official UniFi Cloud Console** ("UniFi Hosting") | Ubiquiti runs the controller *for you* on their infrastructure | **From $29/month** |
>
> Linking your account to `01-unifi-vm` is the first row. Nothing in this
> stack requires a subscription — the controller stays on your hardware and
> your data stays local; the cloud leg is only a signalling path for your
> browser.

> **Keep a local admin account as break-glass.** If you link the account and
> then rely on SSO alone, an account lockout, a lapsed MFA device, or a
> Ubiquiti cloud outage locks you out of a controller sitting on your own LAN.
> Create a local-only admin under Settings → Admins and store the credential
> alongside the Key Vault secrets.

### About the APs already being "set up"

If those three APs were previously claimed or adopted through the UniFi mobile
app or another console, they are not adoptable here until released. Either
remove them from the owning console first, or factory-reset each one (hold
Reset ~10s until the LED cycles). A device that stays stuck in "Managed by
other" has not been released.

## 4) Expose the inform endpoint — router forward + grey-cloud DNS

The APs reach the controller **directly**, not through Cloudflare's proxy.

### 4a) Router forwards

On the home router:

| Forward | To | Why |
|---|---|---|
| TCP 8080 | `192.168.1.75:8080` | device inform — mandatory |
| UDP 3478 | `192.168.1.75:3478` | STUN — instant config push |

Do **not** forward 8443. The admin UI goes through `unifi.ui.com` (step 3a).

### 4b) DNS — grey-clouded A record

`unifi-inform.example.net`, type `A`, **`proxied = false`**, TTL 60, pointed
at the home WAN IP. Declared in `toom-edge`'s `unifi.tf`, alongside the existing
grey-cloud precedent `turn.4rgus.com`.

> **Why not the Tunnel?** It was tried first and abandoned. Proxying inform
> collides with three Cloudflare behaviours at once, and each fix costs more
> than it buys:
>
> 1. **`always_use_https`** — verified against this zone on 2026-08-04:
>    `curl -sI http://grafana.example.net:8080/` returns `301 Location:
>    https://grafana.example.net:8080/`, and that target answers
>    `curl: (35) tlsv1 alert protocol version` because 8080 is an HTTP-only
>    proxied port. Excepting one hostname would mean disabling a zone-wide
>    security default on the zone fronting *every* homelab app and rebuilding
>    it as a hand-maintained Redirect Rule.
> 2. **Access** — the `*.example.net` wildcard gates every new subdomain.
>    Firmware cannot complete an Access login, and Access strips port numbers
>    from protected URLs regardless. It would need a deliberate hole in the gate.
> 3. **STUN** — UDP cannot traverse the HTTP proxy at all (Spectrum is
>    Enterprise-only), so config push would permanently wait for the inform tick.
>
> Going direct removes all three, and the `toom-edge` change shrinks to one
> record. The cost is that the home WAN IP is published in DNS — the same trade
> `turn.4rgus.com` already documents, and the same exposure the existing Plex
> forward already carries.

### 4c) DDNS — the part that is easy to skip and expensive to skip

The connection is **dynamic**. If the WAN IP changes and the record does not
follow, all three APs go offline and stay offline — and the first person to
notice is a family member, not a monitor.

The `cloudflare_ddns` role handles it: a systemd timer on `01-unifi-vm`,
every 5 minutes, that compares the live WAN IP against the record and PATCHes
Cloudflare when they differ.

- Terraform owns the record's **existence** (and its grey-cloud/TTL shape);
  the updater owns its **value**. `unifi.tf` carries
  `lifecycle { ignore_changes = [content] }` so the two do not fight — without
  it, every `toom-edge` apply would revert the live IP to the bootstrap value
  and strand the APs until the next timer tick.
- It fails **loudly and safely**: if the WAN IP cannot be determined from any
  source it exits non-zero and changes nothing, because a stale record still
  lets the APs serve WiFi while a wrong one ends any chance of them getting
  home.
- It runs once during deploy, so a bad token fails the deploy instead of
  surfacing months later as three dead APs.

Its token is a **dedicated** Key Vault secret scoped `Zone:DNS:Edit` on
`example.net` only — deliberately not the `CLOUDFLARE_DNS_API_TOKEN` used for
Traefik's ACME, which can also rewrite the primary zone.

## 5) Set the Override Inform Host — the step that gets skipped

**This is the single setting that decides whether a shipped AP can find home.**

When you adopt an AP on your own LAN, the controller bakes **its own LAN IP**
into the AP's inform URL: `http://192.168.1.75:8080/inform`. Ship that AP and
`192.168.1.75` means nothing on the family house network. The AP goes offline
permanently and needs on-site SSH to recover.

In the controller: **Settings → System → Advanced → Override Inform Host** →
`unifi-inform.<domain>`.

Record the same value in `ansible/host_vars/01-unifi-vm/vars.yml` as
`unifi_override_inform_host` (the setting lives in MongoDB, so Ansible can't
apply it — the var exists for version control and to arm the pre-ship guard),
then set `unifi_require_override_inform_host: true`. After that a deploy fails
loudly rather than letting you ship an AP that will only ever look for
`192.168.1.75`.

## 6) Stage the APs at home, then verify *before* shipping

1. Plug all three APs into your LAN. They appear as pending adoption via L2
   discovery (UDP 10001).
2. Adopt them, create the SSIDs, and **update firmware now** — a firmware update
   over the remote link is far more fragile.
3. Leave them on **DHCP**. Do not give them static IPs from `192.168.1.0/24`;
   they need to take an address from the family house's router.
4. Apply the Override Inform Host (step 5) and force a provision.
5. **Make sure the split-horizon rewrite is deployed before the override.**
   It is declared in `ansible/host_vars/01-dns-lxc/vars.yml` as an
   `adguard_extra_rewrites` entry pointing `unifi-inform.example.net` at
   `192.168.1.75` — so it needs a `01-dns-lxc` deploy, not a click in the
   AdGuard UI. Confirm with `dig +short unifi-inform.example.net` from a LAN
   host: it must answer `192.168.1.75`, not the WAN IP.

   > **Why this is not optional.** The override host resolves to your *WAN* IP.
   > An AP sitting on your own LAN trying to reach your own WAN IP needs NAT
   > hairpinning, and plenty of consumer routers simply do not do it. Without
   > the rewrite, setting the override can knock all three APs offline *on your
   > desk* — and it looks exactly like a broken design when it is only a router
   > limitation. The rewrite also stays correct permanently: LAN-side devices
   > take the short path, the remote APs use public DNS and the forward.

6. **Verify the external path separately — this is the test that matters.**
   The rewrite above means the staged APs are exercising the *internal* path,
   so their staying green proves nothing about the family house. Check the
   forward from genuinely outside the network (phone on mobile data, or any
   host that is not on your LAN):

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' \
     http://unifi-inform.example.net:8080/inform
   ```

   Any HTTP status back means DNS, the forward and the controller are all
   working — the inform endpoint rejects a bare GET, and that rejection is
   itself proof of reachability. A hang or connection refused means the
   forward is wrong, and you would have found that out from a family member.
7. Confirm the inform URL on an AP:
   ```bash
   ssh ubnt@<ap-ip>
   mca-cli-op info
   ```
   The reported inform URL must be `unifi-inform.example.net`, not
   `192.168.1.75`.

Only then pack them up.

## Recovery — the one gap this design still has

If an AP ever loses its inform URL (factory reset, bad firmware update, someone
swaps the router at the family house), the **only** fix is SSH to the AP's local
IP and re-run set-inform:

```bash
ssh ubnt@<ap-local-ip>
set-inform http://unifi-inform.example.net:8080/inform
```

**There is no route into that LAN from here**, so this needs someone on-site —
in practice, a trip. Nothing in this design changes that; the port-forward is on
*your* router, not theirs.

Mitigate it at staging time rather than after the fact:

- Update firmware **before** shipping, on your own LAN. A failed remote firmware
  update is the most likely way an AP ends up needing this.
- Ship all three with identical, verified config so a fault is obviously
  environmental rather than per-device.
- Keep one AP's local IP and SSH credentials written down. Talking a family
  member through `ssh` + one paste is unpleasant but far cheaper than driving.

The only real fix for this gap is a VPN endpoint at the family house (a Pi or
GL.iNet router, ~€50), which would also let you reach the APs directly. That was
considered and declined; it stays the escape hatch if remote recovery ever
becomes a recurring cost.

## Backup and restore

- `/srv/appdata/unifi/config` sits inside the `/srv/appdata` tree that
  `01-backup-lxc`'s restic job already walks — no backup role change needed.
- **Exclude the raw MongoDB data directory from restore expectations.** Restic
  copies `/srv/appdata/unifi/mongo` while mongod is running, so those files are
  not crash-consistent and are not a reliable restore source.
- The supported restore path is the controller's own auto-backup: enable
  **Settings → System → Backups** and restore the `.unf` file into a fresh
  controller. Those live under `config/backup/` and *are* backed up.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| AP stuck "Adopting" then reverts | Controller reachable on 8080 but returning something the AP can't parse — Cloudflare challenge/403, or an Access policy on the inform hostname |
| AP offline right after shipping | Override Inform Host was never set; AP is still trying `192.168.1.75` |
| `unifi-db` exits immediately | `/srv/appdata/unifi/mongo` not owned by uid 999, or `keyctl` feature flag missing on the LXC |
| Controller starts, stats stay empty | MongoDB user missing `dbOwner` on the `_stat` sibling database |
| Config changes to remote APs lag | UDP 3478 forward missing or broken on the router — STUN should work on this path |
| All three APs offline at once, no config change | Suspect the WAN IP moved. `systemctl status cloudflare-ddns.timer` and `journalctl -u cloudflare-ddns` on 01-unifi-vm; compare `dig +short unifi-inform.example.net` against the router's WAN status page |

```bash
# on 01-unifi-vm
sudo systemctl status unifi-compose
docker logs -f unifi-network-application
docker logs -f unifi-db
```

## Known annoyance — the "Upgrade to UniFi OS Server" modal

The upgrade prompt reappears at **every** login, and "Remind Me Later" does not
make it stop. That is how the modal is built, not a broken setting: the dismissal
flag never reaches MongoDB, so there is nothing to fix server-side.

From the shipped frontend bundle
(`/usr/lib/unifi/webapps/ROOT/app-unifi/react/js/swai.<hash>.js`):

```js
const key = `networkServerUpgradeModalDismissed-${id}`;
const dismissed = session.getItem(key) && Number(session.getItem(key)) <= N;
const [isOpen] = useState(!dismissed);
```

The write goes through the app's **sessionStorage** wrapper, not the localStorage
one — both live in the same module, and the genuinely persistent prefs
(`preferredLanguage`, `lastUsedSiteName`, `muteDeviceUpdateToasts`) use the other
one. sessionStorage is scoped to a single tab's lifetime, so the flag is gone by
the next login.

Suppress it browser-side with a userscript (Violentmonkey/Tampermonkey). Match on
`unifi.ui.com` — that is the origin holding the storage, since 8443 is not
forwarded:

```js
// @match https://unifi.ui.com/*
// @run-at document-start
const get = Storage.prototype.getItem;
Storage.prototype.getItem = function (key) {
  if (this === window.sessionStorage && typeof key === 'string' &&
      key.startsWith('networkServerUpgradeModalDismissed')) return '-1e999';
  return get.call(this, key);
};
```

`-1e999` parses to `-Infinity`, which satisfies `<= N` for any finite counter.

**Do not patch the bundle inside the container.** The filename is content-hashed,
so a bind-mount override breaks on every image bump — and Renovate bumps this
image regularly. A client-side nag belongs on the client.

## Why not UniFi OS Server?

> **Superseded — this argument lost.** The migration it argues against happened
> on 2026-08-19: `01-unifi-vm` (VMID 152) runs UniFi OS Server today, and the
> `01-unifi-lxc` guest this section defends is destroyed. Kept because the
> reasoning is still the right way to weigh the trade-off, and because the
> "migration outline" below is the record of what was actually done. Read it as
> history, not as current guidance — the references to `01-unifi-lxc` and
> `192.168.1.8` describe the retired guest.

Since ~March 2026 Ubiquiti's *recommended* self-hosting path is **UniFi OS
Server**, not the standalone Network application this stack deploys. It was
evaluated and rejected for now:

**What it would add:** full Site Manager integration, Teleport VPN, Site Magic,
UniFi Identity, cloud backup — the UniFi OS console experience without buying a
Cloud Key.

**Why it does not help here:**

- **It does not solve the inform problem.** Teleport is a *client* VPN — it gets
  your laptop into a network, not an AP out to a controller. Site Magic is
  site-to-site SD-WAN and needs a UniFi **gateway** at both ends; the family
  house has three APs and no gateway. Remote APs would still need TCP 8080
  reachable, exactly as documented above.
- **Podman only — Docker is explicitly unsupported.** This repo's `docker` role
  and `docker_hosts` inventory group would not apply.
- **Requires a privileged LXC.** Unprivileged does not work. This is a weaker
  objection than it first appears: every bind-mounted guest here
  (`01-torrent-lxc`, `01-observability-lxc`, `01-tailscale-lxc`, and now
  `01-unifi-lxc`) already runs privileged for UID parity, so this would not be
  a new exception.
- Community workarounds are needed for sysctl errors, `su`/group restrictions,
  Podman's `/proc` mount, and `/dev/net/tun`; it also wants ~20 GB.

**Revisit if:** you put a UniFi gateway (UCG/UDM) at the family house — that
makes Site Magic viable and turns remote adoption into a solved problem, at
which point UniFi OS Server becomes clearly the better base. Migration path is
a controller `.unf` backup restored into the new install.

**How long the current path actually survives.** The modal's claim that Network
Server "will not support upcoming Network versions" is stronger than anything
Ubiquiti has attached a date to. The concrete dependency here is the *image*, and
LinuxServer have stated their position plainly: they will maintain
`docker-unifi-network-application` for as long as Ubiquiti keep publishing the
install packages, and they do **not** plan a UniFi OS Server image —
containerising it is feasible but carries administrative overhead they have
declined for now. So the signal to watch is **Ubiquiti pulling the Debian
packages**, not the nag screen. Until then this stack is fine, in maintenance
mode: security and bug fixes, no new features.

**Migration outline, for when a trigger does fire:**

1. Take a controller backup (Settings → System → Backups) and copy the `.unf`
   off `01-unifi-lxc`. That file is the only artefact that crosses — the MongoDB
   data directory does not migrate.
2. Stand up a **new** guest rather than converting 166 in place. UniFi OS Server
   wants Podman ≥ 4.3 on Ubuntu 24.04+ / Debian 13+ and ~20 GB, and this repo's
   `docker` role and `docker_hosts` group do not apply to it — it needs its own
   role. Keep 166 running until the new one is verified; APs keep serving clients
   from cached config either way.
3. Restore the `.unf` into the fresh install. Override Inform Host travels inside
   the backup, so the APs' inform URL does not change.
4. Repoint the router forward for **TCP 8080** (and UDP 3478) at the new guest.
   8080 is unchanged on UniFi OS Server, so the APs need no reconfiguration at
   all — they keep informing at the same hostname and port.
5. The admin UI moves off 8443; UniFi OS Server binds its own set (3478, 5005,
   5514, 6789, 8080, 8444, 8880, 8881, 8882, 9543, 10003, 11443). Confirm UI
   access before decommissioning 166.
6. Remove the duplicate local admin after enabling remote access, or the UI
   account and the restored local admin collide on one email address.

**The APs are not re-adopted.** Adoption state travels inside the `.unf` — the
backup carries the device list and the per-device credentials the controller
authenticates with, so a restored controller *is* the same controller as far as
the APs are concerned. They reconnect on their next inform tick, typically within
a minute. Nothing is re-provisioned and nothing is touched at the family house.

The failure mode actually worth planning for is a **version-incompatible
backup**: a `.unf` cannot be restored into an older Network version than the one
that produced it. That check is free, and it is the one thing that turns this
from a 15-minute job into a rebuild. Read the Network version off the target's
UI (UniFi OS Server: Settings → System) and gate on it:

```bash
scripts/ops/unifi_backup_version_check.py 10.4.57
```

It reads the newest autobackup's recorded version off 166 and exits non-zero if
the restore would be rejected — usable as a pre-flight gate, not just a report.

> **Do not confuse the two version lines.** The download page lists *UniFi OS
> Server 5.1.21* — that is the **UniFi OS** version, the same line the consoles
> run (UDM/Cloud Key were on 5.1.25/5.1.26 in Aug 2026). Network is a separate
> application on the **10.x** line installed on top of it, and it updates
> independently. So the number to feed the check is the Network version shown
> inside the running UniFi OS Server, not the 5.x installer version.
>
> As of **UniFi OS Server 5.1.21** (07 Jul 2026) the bundled application is
> **UniFi Network 10.4.57** — byte-identical to what 166 runs, so the restore is
> an exact-version match with no schema migration at all. If a future build ever
> lands *older* than the backup, update Network *inside* UniFi OS Server first,
> then restore.

Even a failed restore does not automatically mean a site visit. As long as an AP
keeps informing at `unifi-inform.example.net:8080`, a controller that does not
recognise it lists it as **pending adoption**, and Layer 3 adoption works
remotely from your browser. On-site `set-inform` is only required if an AP loses
its inform URL outright — factory reset, or someone rebuilding the family house's
router; see [Recovery](#recovery--the-one-gap-this-design-still-has). Repointing
a port forward does not cause that.

Do not decommission 166 until all three APs show connected on the new controller.

### Verifying a restore before cutover

Restoring the `.unf` is not enough on its own — check that the *controller-level*
settings came across, not just the site. The one that decides whether remote APs
can find the controller lives in the **`super_mgmt`** document, not `mgmt`:

```bash
# on 01-unifi-vm
sudo -u uosserver env XDG_RUNTIME_DIR=/run/user/1002 podman exec uosserver \
  mongo --quiet --port 27117 ace --eval \
  'JSON.stringify(db.setting.find({key:"super_mgmt"},{override_inform_host:1,override_inform_host_location:1,autobackup_enabled:1,_id:0}).toArray())'
```

Looking in `mgmt` returns `{}` and reads as "the inform host was never set",
which is wrong and would send you chasing a non-problem. Expect:

```json
{"override_inform_host": true,
 "override_inform_host_location": "unifi-inform.example.net",
 "autobackup_enabled": true}
```

Verified on the 2026-08-19 migration, all of which transferred with the `.unf`:

| Check | Query | Result |
|---|---|---|
| Devices adopted | `db.device.count()` | 3, all `adopted: true` |
| WLANs | `db.wlanconf.count()` | 3 |
| Admins | `db.admin.count()` | 1 |
| Regulatory domain | `db.setting.find({key:"country"})` | `348` (Hungary) |
| Inform host | `super_mgmt` | `unifi-inform.example.net` |
| Auto-backup | `super_mgmt` | enabled, `30 0 * * *`, keep 7 |

The container ships the legacy `mongo` shell, not `mongosh`, and Network's
MongoDB listens on **27117** (not 27017).

Note the site's country came back as Hungary only *because* of the restore — a
fresh UniFi OS Server setup defaults to United States, which is the wrong
regulatory domain for channel and TX-power limits here.

### Sketch: `01-unifi-vm`

A first pass at the target stack lives on the `feat/unifi-os-server-vm` branch:

| Piece | Path |
|---|---|
| Terraform stack | `infra-proxmox/terraform/01-unifi-vm/` |
| Ansible role | `ansible/roles/unifi_os_server/` |
| Host vars | `ansible/host_vars/01-unifi-vm/vars.yml` |
| Playbook | `ansible/playbooks/services/01-unifi-vm.yml` |

VMID 152, `192.168.1.75/24`, 40 GB, one VirtIO-FS share (`homelab-appdata`)
carrying the host's `/srv/appdata` — the same mapping 01-media-vm uses, which
is what puts controller backups in the tree restic already walks. The host is
deliberately **absent from `docker_hosts`**: UniFi OS Server runs Podman.

Storage is split the way 01-media-vm splits `homelab_local_state_paths`. The
live database stays on the VM's local disk — VirtIO-FS does not give an
embedded database the write/locking semantics it expects, and UniFi's raw data
directory is not a restore source anyway. Only `.unf` auto-backups go on the
share, because those are the only artefact a restore consumes.

**Verified on a real 5.1.21 install** (01-unifi-vm, 2026-08-19):

| Question | Answer |
|---|---|
| Unattended install? | **Yes** — `--non-interactive`. The installer also exposes `--force-install`, `--network-mode <slirp4nets\|pasta>`, `--web-port`, `--uninstall` |
| systemd unit | `uosserver.service` (**not** `unifi-os-server`), plus a `uosserver-updater.service` that self-updates the appliance |
| Installer | ~840 MB ELF; sha256 `77e3feac1595779402dd87ff8d20d66faa39c87b572646f86ff0006711262445` |
| Admin UI | `https://<host>:11443/` |
| Ports listening | 8080/tcp (**inform**), 11443/tcp, 3478/udp, 10003/udp — 8080 unchanged, so the APs need no reconfiguration |
| CLI | `uosserver start|stop|status|shell|support|version`; `uosserver-purge` uninstalls |

**The data directory cannot be relocated.** The installer runs a *rootless
Podman* container as the `uosserver` user and keeps everything in named volumes
under that account's home:

```
/home/uosserver/.local/share/containers/storage/volumes/
  uosserver_var_lib_unifi/_data/   <- backup/ db/ keystore system.properties
  uosserver_var_lib_mongodb/_data/
  uosserver_persistent/_data/ ...
```

The layout inside `uosserver_var_lib_unifi` mirrors the LXC's `/config/data`
exactly, so `scripts/ops/unifi_backup_version_check.py` works against it with
`--meta-path`.

Because the appliance owns those paths, pointing its backup directory at the
VirtIO-FS share is **not possible**. The role instead mirrors the `.unf`
auto-backups across on an hourly systemd timer
(`unifi-os-backup-mirror.timer`), which is the same split 01-media-vm uses in
`homelab_local_state_paths`: live database on local disk, backups copied to
`/srv/appdata`. Verified end-to-end — a file placed in the appliance volume
appears on the Proxmox host under `/srv/appdata/unifi-os/backup/`.

**Two things to set on first-run setup:** the API reports
`"autoBackupEnabled": false` on a fresh install, so auto-backups must be turned
on or the mirror has nothing to copy; and `uosserver-updater.service` means the
bundled Network version can move on its own, so re-run the version check before
any restore rather than trusting the number recorded here.

## Sources

- [LinuxServer — UniFi Network Application](https://docs.linuxserver.io/images/docker-unifi-network-application/)
- [Ubiquiti — Remote Adoption (Layer 3)](https://help.ui.com/hc/en-us/articles/204909754-Remote-Adoption-Layer-3)
- [Ubiquiti — Understanding UniFi Cloud Architecture](https://help.ui.com/hc/en-us/articles/30319146145175-Understanding-UniFi-Cloud-Architecture)
- [Ubiquiti — Self-Hosting UniFi](https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi)
- [LinuxServer — Unifi OS Server & Unifi Network Application](https://info.linuxserver.io/issues/2026-02-22-unifi-network-application/)
- [Cloudflare — Network ports proxied by default](https://developers.cloudflare.com/fundamentals/reference/network-ports/)
