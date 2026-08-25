# Homelab Platform (Current)

## Goals
- Keep media workloads in `01-media-vm` (Docker/Compose).
- Keep torrents isolated in `01-torrent-lxc`, with **incomplete** downloads on a local SSD staging mount.
- Avoid NFS for internal storage paths (especially `mergerfs` over NFS). Proxmox host owns disks and shares storage into guests.

## Network Assumptions
- LAN: `192.168.1.0/24`
- Gateway/router: `192.168.1.1`
- Proxmox host: `192.168.1.239` (fixed)
- Local DNS: `01-dns-lxc` (AdGuard Home; DHCP DNS points here)
- Internal DNS zone: `home.arpa`

## Nodes (VMs + LXCs)

| Component             | Type | VMID | IP           | Hostname             | Purpose |
|-----------------------|------|------|--------------|----------------------|---------|
| 01-hypervisor         | host | n/a  | 192.168.1.239 | proxmox.home.arpa     | Proxmox VE + storage owner |
| 01-edge-lxc           | LXC  | 160  | 192.168.1.2  | 01-edge-lxc          | Cloudflare tunnel client |
| 01-reverse-proxy-lxc  | LXC  | 162  | 192.168.1.4  | 01-reverse-proxy-lxc | Traefik reverse proxy entrypoint |
| 01-dns-lxc            | LXC  | 161  | 192.168.1.3  | 01-dns-lxc           | AdGuard Home (LAN DNS) |
| 01-media-vm           | VM   | 150  | 192.168.1.70 | 01-media-vm          | Docker/Compose media stack |
| 01-myapps-vm          | VM   | 151  | 192.168.1.72 | 01-myapps-vm         | Docker/Compose self-hosted apps (netcheck) |
| 01-torrent-lxc        | LXC  | 171  | 192.168.1.71 | 01-torrent-lxc       | qBittorrent only |
| 01-backup-lxc         | LXC  | 173  | 192.168.1.73 | 01-backup-lxc        | Restic backup agent |
| 01-observability-lxc  | LXC  | 174  | 192.168.1.74 | 01-observability-lxc | Grafana, Prometheus, Loki, Tempo + adguard/blackbox/cadvisor exporters |
| 01-tailscale-lxc      | LXC  | 165  | 192.168.1.7  | 01-tailscale-lxc     | Tailscale subnet router for CI/LAN reachability |
| 01-unifi-vm           | VM   | 152  | 192.168.1.75 | 01-unifi-vm          | UniFi OS Server (network controller) |
| 01-code-lxc           | LXC  | 176  | 192.168.1.78 | 01-code-lxc          | code-server (VS Code in the browser) |

## Storage Model

**Proxmox host (`pve`) owns storage and mountpoints:**
- Media disks mounted at `/mnt/d8`, `/mnt/d16`, `/mnt/d24`
- `mergerfs` mount at `/srv/media`
- Appdata disk mounted at `/srv/appdata`
- Torrent staging SSD mounted at `/srv/staging-ssd` (host-only; not configured as a Proxmox storage id)

**Guests consume storage without NFS:**
- `01-media-vm`: VirtIO-FS shares (Proxmox Directory Mappings)
  - `homelab-appdata` -> `/srv/appdata`
  - `homelab-media` -> `/srv/media`
- `01-torrent-lxc`: Proxmox mount points (host bind mounts)
  - `/srv/appdata/qbittorrent` (bind mount)
  - `/srv/media/downloads` (bind mount)
  - `/srv/torrent-staging` (bind mount from `/srv/staging-ssd/torrent-staging`)
- `01-backup-lxc`: Proxmox mount point (host bind mount)
  - `/srv/appdata` (bind mount)
  - `/mnt/d16/backups/macbook-backup` -> `/srv/appdata/macbook-backup` (Time Machine share)
- `01-observability-lxc`: Proxmox mount point (host bind mount)
  - `/srv/appdata/observability` (bind mount)
- `01-tailscale-lxc`: Proxmox mount point (host bind mount)
  - `/srv/appdata/tailscale` -> `/var/lib/tailscale` (root-only node identity state)
- `01-unifi-vm`: VirtIO-FS share
  - `homelab-appdata` -> `/srv/appdata`
- `01-myapps-vm`: VirtIO-FS share, mounted at a DIFFERENT path from every other guest
  - `homelab-appdata` -> `/srv/backup-share`
  - `/srv/appdata` on this guest is a **local ext4 directory**, not the share: it
    holds live state (chromium profile, digest's state.db, garmin-health's raw
    dumps, jobs-refresh deploy keys) that predates the share and is bind-mounted
    into running containers. Mounting the share over it would shadow all of it.
    Snapshots are mirrored out to `/srv/backup-share` instead.
- `01-code-lxc`: Proxmox mount point (host bind mount)
  - `/srv/appdata/code` (bind mount; code-server state, projects and CLI auth)

## Service Placement
- `01-media-vm`: Docker/Compose app stack (Plex, *arr apps, etc.). No reverse proxy here.
- `01-torrent-lxc`: qBittorrent only. Incomplete to staging SSD; completed to `/srv/media/downloads`.
- `01-reverse-proxy-lxc`: single HTTP(S) entrypoint with file-based routing to LAN targets.
- `01-edge-lxc`: Cloudflare Tunnel client pointing to Traefik.
- `01-dns-lxc`: LAN DNS server for internal hostnames.
- CI: GitHub-hosted runners connect via Tailscale (`01-tailscale-lxc` subnet router).
- `01-myapps-vm`: general-purpose Docker/Compose host for self-hosted apps.
  Long-running containers: netcheck (network diagnostics on :8787, fronted by
  Traefik at netcheck.example.com), chromium, playwright-mcp, cadvisor.
  Timer-driven oneshots: notification-digest (four daily windows plus weekly,
  overnight, patreon and positions runs), garmin-sync, garmin-report,
  withings-sync, jobs-refresh, and the local-state mirror.
  **Not stateless** -- see the storage note above.
- `01-tailscale-lxc`: Tailscale subnet router for secure CI access into LAN targets.
- `01-backup-lxc`: Restic backup execution and Time Machine share.
- `01-observability-lxc`: Grafana, Prometheus, Loki, and Tempo observability stack.
- `01-unifi-vm`: UniFi OS Server. Live database on the local disk, backups on the share.
- `01-code-lxc`: code-server, reached through Traefik + Cloudflare Access. Replaced the
  retired 01-agent-lxc; state and repositories live on the `/srv/appdata/code` bind mount.
- Secrets: Azure Key Vault (Frankfurt / germanywestcentral), fetched at deploy time — `az login` locally, GitHub OIDC in CI. No in-cluster secrets service.
