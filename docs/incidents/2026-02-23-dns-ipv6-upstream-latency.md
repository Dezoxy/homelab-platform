# Incident: AdGuard Upstream Latency Spikes (IPv6 / RA Configuration)

## Summary

AdGuard Home showed very high upstream response times (for example `~650 ms` to `~1900 ms`) for encrypted upstreams (`dns.google`, `dns.quad9.net`) in Grafana.

The primary network issue was incomplete IPv6 on the Proxmox host and DNS LXC path:

- `pve` bridge (`vmbr0`) received Router Advertisements (RA) but did not apply them because Linux bridge forwarding requires `accept_ra=2`.
- `01-dns-lxc` initially had no public IPv6 config/default route in Proxmox, so AdGuard could not use IPv6 upstream connectivity cleanly.

A secondary observability issue made the graph look worse/more confusing:

- Grafana panel used the AdGuard exporter’s pre-aggregated average metric (`adguard_top_upstreams_avg_response_time_seconds`), which is a sticky average and not per-query live latency.

## Impact

- Grafana showed high/stepped upstream latency values for AdGuard encrypted upstreams.
- Troubleshooting confidence was reduced because the panel looked like current live latency, but it was a lagging average metric.
- DNS resolution still worked for most clients, but upstream connection setup/fallback behavior (especially around IPv6) could inflate observed averages.

## Symptoms Observed

- Grafana panel showed:
  - `https://dns.google:443/dns-query` around `1900 ms`
  - `tls://dns.google:853` around `1300 ms`
  - Quad9 DoH/DoT around `650-700 ms`
- `pve` and `01-dns-lxc` initially had only link-local IPv6 (`fe80::/64`) and no default IPv6 route.
- `dig -6` on `pve` initially failed (no usable IPv6 DNS path).
- `01-dns-lxc` could resolve via local `::1` (AdGuard on loopback), but that did not prove public IPv6 egress.

## Timeline (2026-02-23 to 2026-02-24)

1. High AdGuard upstream latency was observed in Grafana.
2. DNS health check script (`scripts/ci/dns-healthcheck.sh`) was run from `pve`; it showed mostly successful DNS transport behavior and did not reproduce the Grafana numbers.
3. Latency benchmarking showed actual DNS query time was low, but occasional setup spikes inflated averages.
4. Initial suspicion was router LAN IPv6/RA not being advertised.
5. `rdisc6 vmbr0` on `pve` proved RA was present on wired LAN.
6. Root cause on `pve` was identified:
   - `vmbr0` is a bridge with IPv6 forwarding enabled
   - Linux requires `net.ipv6.conf.vmbr0.accept_ra=2` to accept RA on a forwarding interface
7. `pve` IPv6 was fixed:
   - `iface vmbr0 inet6 auto`
   - `accept_ra=2` applied on `vmbr0`
8. `01-dns-lxc` IPv6 was enabled in Terraform/Proxmox (`ip6=auto`) so the container gets global IPv6 + default route.
9. Grafana panel template was improved to show clearer legends and a short-window view, and Jinja-safe legend escaping was added.

## Root Cause

### 1) Proxmox bridge RA handling (`pve`)

The Proxmox host received IPv6 RA, but `vmbr0` did not autoconfigure a global IPv6 address because:

- `vmbr0` had IPv6 forwarding enabled (bridge behavior)
- Linux ignores RA on forwarding interfaces unless `accept_ra=2`

Result:

- `pve` stayed on link-local IPv6 only
- no default IPv6 route on `vmbr0`

### 2) DNS LXC missing IPv6 configuration (`01-dns-lxc`)

The DNS LXC initially had only link-local IPv6 and no public IPv6 route. AdGuard could still function over IPv4, but IPv6 upstream attempts/fallback behavior could contribute to inflated encrypted upstream timing averages.

Additionally, the generated container network file had `IPv6AcceptRA = false` until the Proxmox CT NIC was configured with IPv6 (`ip6=auto`).

### 3) Grafana metric semantics (misleading presentation)

The panel used:

- `topk(10, adguard_top_upstreams_avg_response_time_seconds)`

This metric is already an average from AdGuard/exporter stats, so the graph is a lagging, step-like average rather than a direct per-query latency graph. This made the values look "fake" or stale after the network fix.

## Diagnostics That Confirmed the Issue

### `pve`

- `rdisc6 vmbr0` returned:
  - Prefix `2001:4c4e:1c89:9700::/64`
  - Router `fe80::a2b5:3cff:fe98:303f`
  - RDNSS `2001:4c4e:1c89:9700::1`
- After setting `accept_ra=2` on `vmbr0`, `pve` immediately received:
  - global IPv6 on `vmbr0`
  - default IPv6 route
- `dig -6 @2001:4860:4860::8888 google.com` succeeded from `pve`

### `01-dns-lxc`

- Before fix:
  - only link-local IPv6
  - no default IPv6 route
  - public IPv6 route lookup failed
- After Proxmox/Terraform IPv6 config (`ip6=auto`):
  - container received global IPv6 + default route
  - public IPv6 DNS queries succeeded

## Remediation Applied

### Proxmox host (`pve`)

`/etc/network/interfaces` was configured with a separate IPv6 stanza for the bridge:

```ini
iface vmbr0 inet6 auto
    post-up /bin/sh -c 'echo 2 > /proc/sys/net/ipv6/conf/vmbr0/accept_ra'
```

Why:

- `inet6 auto` enables SLAAC/RA autoconfiguration
- `accept_ra=2` allows RA on a forwarding bridge interface (`vmbr0`)

### DNS LXC Terraform / Proxmox

Terraform for `01-dns-lxc` was updated so the container NIC gets IPv6 automatically (SLAAC/RA):

- `infra-proxmox/terraform/01-dns-lxc/main.tf`
- `infra-proxmox/terraform/01-dns-lxc/variables.tf`
- `infra-proxmox/terraform/01-dns-lxc/terraform.tfvars.example`

Key change:

- `ipv6 { address = "auto" }` (via variable default)

### Grafana / AdGuard Panel Clarity

The AdGuard upstream latency panel template was updated to:

- clarify the panel title (it is an average gauge metric)
- show upstream names in the legend (`{{upstream}}`, escaped for Jinja)
- add a short-window (`5m`) averaged view for easier recent trend reading

Template file:

- `ansible/templates/grafana-dashboards/ingress-dns.json.j2`

## Validation / Success Criteria

Use these checks after changes:

### `pve`

```bash
ip -6 addr show dev vmbr0
ip -6 route
cat /proc/sys/net/ipv6/conf/vmbr0/accept_ra
dig -6 @2001:4860:4860::8888 google.com
```

Expected:

- global `2001:...` address on `vmbr0`
- default route via router link-local IPv6
- `accept_ra=2`
- successful `dig -6`

### `01-dns-lxc`

```bash
ip -6 addr
ip -6 route
dig -6 @2001:4860:4860::8888 google.com
```

Expected:

- global IPv6 + default route
- successful public IPv6 DNS query

### Observability

- Recheck AdGuard query logs for upstream timeouts/retries.
- Observe Grafana for at least 24 hours after the fix.
- Expect fewer multi-second spikes and a more understandable panel presentation.

## Remaining Caveat (Separate From This Incident)

The ISP router can advertise its own IPv6 DNS server (RDNSS), which may cause some clients to use router IPv6 DNS directly instead of AdGuard (`192.168.1.3`). This is a separate client-DNS-path issue and not the root cause of the upstream latency incident.

## Preventive Actions

- Keep DNS LXC IPv6 configured via Terraform (`ip6=auto`) instead of manual container edits.
- Document the Proxmox bridge `accept_ra=2` requirement for IPv6 on `vmbr0`.
- Treat AdGuard exporter average metrics as lagging indicators; use direct probes/logs for real-time troubleshooting.
- Prefer Grafana legends that show upstream labels to avoid ambiguous series names.
