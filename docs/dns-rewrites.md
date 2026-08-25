# DNS Rewrites

Source of truth: `ansible/host_vars/01-dns-lxc/vars.yml`

## Current Rewrites (Sorted)

| Hostname | IP |
| --- | --- |
| `01-dns-lxc.home.arpa` | `192.168.1.3` |
| `01-edge-lxc.home.arpa` | `192.168.1.2` |
| `01-media-vm.home.arpa` | `192.168.1.70` |
| `01-myapps-vm.home.arpa` | `192.168.1.72` |
| `01-reverse-proxy-lxc.home.arpa` | `192.168.1.4` |
| `01-torrent-lxc.home.arpa` | `192.168.1.71` |
| `bazarr.example.com` | `192.168.1.4` |
| `lingarr.example.com` | `192.168.1.4` |
| `netcheck.example.com` | `192.168.1.4` |
| `overseerr.example.com` | `192.168.1.4` |
| `pentest.example.com` | `192.168.1.4` |
| `plex.example.com` | `192.168.1.4` |
| `prowlarr.example.com` | `192.168.1.4` |
| `proxmox.home.arpa` | `192.168.1.239` |
| `proxmox.example.com` | `192.168.1.4` |
| `qb.example.com` | `192.168.1.4` |
| `radarr.example.com` | `192.168.1.4` |
| `reverse-proxy.example.com` | `192.168.1.4` |
| `sonarr.example.com` | `192.168.1.4` |
| `tautulli.example.com` | `192.168.1.4` |
| `unifi-inform.example.net` | `192.168.1.75` |

## How To Use These Hostnames (Option A)

Goal: one public domain for users (`*.example.com`) and a separate internal
domain for infra (`*.home.arpa`).

Traffic paths:

| What you type | DNS resolution (LAN) | Where it goes | TLS warning? |
| --- | --- | --- | --- |
| `192.168.1.x` | none | Direct to the service IP | Depends on the service |
| `*.home.arpa` | AdGuard rewrite → service IP | Direct to the service (no Traefik) | Yes if you try `https://` |
| `*.example.com` | AdGuard rewrite → reverse proxy (`192.168.1.4`) | Traefik → backend | No (Traefik handles TLS) |

Why this helps:

- You keep `home.arpa` for infra/SSH and “raw” access.
- You use `example.com` for user-facing apps with proper HTTPS certs.
- No need to install a local CA on every device.

## Tunnel Origin Choices

You have two ways to point your Cloudflare Tunnel at Traefik:

**Option A: Cloudflare → Traefik over HTTP (port 80)**

- Tunnel origin: `http://01-reverse-proxy-lxc.home.arpa:80`
- Works with current repo defaults (`traefik_enable_web_entrypoint_with_tls: true` and `traefik_redirect_web_to_websecure: false`).
- If you later enable `traefik_redirect_web_to_websecure: true`, this option causes `ERR_TOO_MANY_REDIRECTS`.

**Option B (recommended for end-to-end encrypted tunnel origin): Cloudflare → Traefik over HTTPS (port 443)**

- Tunnel origin: `https://01-reverse-proxy-lxc.home.arpa:443`
- This avoids HTTP origin traffic between cloudflared and Traefik.
- Because Traefik certs are for `*.example.com` (not `01-reverse-proxy-lxc.home.arpa`),
  set `origin_request.no_tls_verify = true` in tunnel ingress rules.

### Example tunnel config (Option B)

```hcl
locals {
  traefik_origin = "https://01-reverse-proxy-lxc.home.arpa:443"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab_config" {
  account_id = var.account_id
  tunnel_id  = var.tunnel_id

  config = {
    ingress = [
      {
        hostname = "radarr.example.com"
        service  = local.traefik_origin
        origin_request = { no_tls_verify = true }
      },
      {
        hostname = "proxmox.example.com"
        service  = local.traefik_origin
        origin_request = { no_tls_verify = true }
      },
      { service = "http_status:404" },
    ]
  }
}
```

The key idea: Cloudflare forwards by hostname, Traefik routes by hostname.
No app-side TLS changes are needed in Radarr/Sonarr/etc.

## How To Add A Rewrite

Edit `ansible/host_vars/01-dns-lxc/vars.yml` and add a new entry under `adguard_extra_rewrites`:

```yaml
adguard_extra_rewrites:
  - domain: "new-host.home.arpa"
    answer: "192.168.1.50"
```

Then run the deploy workflow for `01-dns-lxc` (ansible only).
