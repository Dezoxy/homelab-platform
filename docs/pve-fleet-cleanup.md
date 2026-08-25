# PVE Fleet Cleanup

The homelab cleanup script can run entirely from the Proxmox host.

Installed path on `pve`:

```bash
sudo /usr/local/sbin/pve-fleet-cleanup
```

Installed `systemd` units on `pve`:

```bash
/etc/systemd/system/pve-fleet-cleanup.service
/etc/systemd/system/pve-fleet-cleanup.timer
```

What it does:

- cleans the Proxmox host locally
- uses `pct exec` for running LXCs
- uses `qm guest exec` for running VMs through the QEMU guest agent
- does not require guest-to-guest SSH from `pve`

Audit only:

```bash
sudo /usr/local/sbin/pve-fleet-cleanup audit
```

Cleanup pass:

```bash
sudo /usr/local/sbin/pve-fleet-cleanup clean
```

Timer schedule:

```bash
Sun 06:00
```

Timer management:

```bash
sudo systemctl status pve-fleet-cleanup.timer
sudo systemctl list-timers pve-fleet-cleanup.timer --all
sudo systemctl start pve-fleet-cleanup.service
```

Current cleanup actions:

- `apt-get clean`
- remove `/var/lib/apt/lists/*`
- `journalctl --vacuum-size=100M`
- remove old files from `/tmp` and `/var/tmp` older than 7 days
- `docker image prune -af`
- `docker builder prune -af`
- remove `pip` and `whisper` caches from `/root/.cache` and `/home/*/.cache`

Repo source:

```bash
scripts/ops/pve_fleet_cleanup.py
```
