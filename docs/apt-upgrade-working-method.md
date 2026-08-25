# Fleet Apt Upgrade Working Method

This document explains how `make update-all` runs `apt update` + `apt dist-upgrade` across every VM and LXC in the homelab and leaves behind a dated log of what was actually upgraded on each host.

## 1) Entry Point

The only command you run:

```
make update-all
```

It writes the log to:

```
logs/apt-upgrade-YYYY-MM-DD.log
```

The `logs/` directory is created automatically and is ignored by git via the existing `*.log` rule in `.gitignore`, so logs stay local.

## 2) What Gets Hit

Everything in `ansible/inventory.ini`. At the time of writing that is 10 hosts:

- VMs: `01-media-vm`
- LXCs: `01-torrent-lxc`, `01-observability-lxc`, `01-backup-lxc`, `01-edge-lxc`, `01-dns-lxc`, `01-reverse-proxy-lxc`, `01-tailscale-lxc`

All hosts in `inventory.ini` use `ansible_user=toomhorvath` and `ansible_ssh_private_key_file=~/.ssh/toomhorvath`, so no per-host SSH plumbing is needed — Ansible reads both from the inventory.

If a host is added to or removed from `inventory.ini` (via `make gen-inventory`), `make update-all` automatically picks it up on the next run.

## 3) What Actually Happens

The Makefile target is a thin wrapper around one Ansible playbook:

```
ansible/playbooks/maintenance/apt-upgrade-log.yml
```

It has two plays.

### Play 1 — runs on every host in parallel

Flags: `become: true`, `gather_facts: false`, `ignore_unreachable: true`.

Tasks, in order:

1. **Update apt cache** (`ansible.builtin.apt: update_cache=true cache_valid_time=0`) — forces a fresh refresh, never reuses a cached index.
2. **List upgradable packages** (`command: apt list --upgradable`) — captured into `upgradable_raw`. Marked `changed_when: false` because listing is read-only.
3. **Store upgradable package list** (`set_fact: apt_upgraded=...`) — the raw output is filtered to strip the `Listing...` header line, leaving just the package lines. This fact survives on the host for the duration of the run and is read later by the log-writing play.
4. **Upgrade all packages** (`apt: upgrade=dist autoremove=true autoclean=true`) — full `dist-upgrade`, remove orphaned deps, clean the local archive.

`ignore_unreachable: true` at the play level means a single offline host does not abort the run for the others — it is simply skipped, and `apt_upgraded` never gets set on it.

### Play 2 — runs once on the Ansible controller (your laptop)

Flags: `hosts: localhost`, `connection: local`, `gather_facts: false`.

Tasks:

1. **Ensure logs directory exists** — creates the parent directory of `APT_LOG_FILE` if missing.
2. **Write apt upgrade log** (`ansible.builtin.template`) — renders `templates/apt-upgrade-log.j2` into the file at `APT_LOG_FILE`.

The template iterates over `groups['all']` and reads `hostvars[host].apt_upgraded` for each host. Three branches:

- fact is `none` (unreachable / first task failed) → `(unreachable or upgrade failed)`
- fact is empty list → `(up to date — nothing to upgrade)`
- fact is non-empty list → one line per package

The package line is the raw `apt list --upgradable` output, which looks like:

```
curl/stable,now 7.88.1-10+deb12u8 amd64 [upgradable from: 7.88.1-10+deb12u7]
```

So you get the package name, new version, architecture, and the version it was upgraded from — all in a single line per package.

## 4) The Makefile Glue

In `Makefile`:

```makefile
LOG_DIR  ?= logs
LOG_DATE := $(shell date +%Y-%m-%d)

update-all: setup
	@mkdir -p $(LOG_DIR)
	@ANSIBLE_CONFIG=ansible/ansible.cfg \
	 ANSIBLE_DEPRECATION_WARNINGS=False \
	 ANSIBLE_HOST_KEY_CHECKING=True \
	 APT_LOG_FILE=$(CURDIR)/$(LOG_DIR)/apt-upgrade-$(LOG_DATE).log \
	 $(VENV)/bin/ansible-playbook \
	     -i ansible/inventory.ini \
	     ansible/playbooks/maintenance/apt-upgrade-log.yml
```

Three things worth noting:

- `setup` is a prerequisite, so a missing `.venv` triggers a fresh install of the pinned Ansible version from `scripts/ci/versions.sh` before the playbook runs.
- `APT_LOG_FILE` is passed as an **environment variable**, not an extra-var. The playbook reads it with `lookup('env', 'APT_LOG_FILE')`. This keeps the log path entirely a controller-side concern — the managed hosts never see it.
- `ANSIBLE_HOST_KEY_CHECKING=True` prevents maintenance from authenticating to an unexpected server. Guest keys are read through pinned `pve` into a temporary trust file, so rebuilt guests do not require manual enrollment.

## 5) Sample Log Output

```
==========================================
Homelab apt upgrade log
Date: 2026-04-18T09:12:44Z
==========================================

## 01-backup-lxc (192.168.1.73)
  curl/stable,now 7.88.1-10+deb12u8 amd64 [upgradable from: 7.88.1-10+deb12u7]
  libcurl4/stable,now 7.88.1-10+deb12u8 amd64 [upgradable from: 7.88.1-10+deb12u7]

## 01-dns-lxc (192.168.1.3)
  (unreachable or upgrade failed)

...
```

## 6) Relationship to Existing Playbooks

There is a separate play at `ansible/playbooks/bootstrap/00-system-updates.yml` that is invoked during `make deploy TARGET=<host> MODE=full` as part of bringing up or fully reconciling a single host. `MODE=config` does not run package upgrades. The full-deploy update is scoped to a target, handles reboot-if-required, and does not produce a log.

`make update-all` is **fleet-wide, log-producing, and does not reboot**. It is meant for routine patching where you want to know exactly what moved.

If you want per-host on-demand upgrades, use `make deploy TARGET=<host> MODE=full`. If you want "patch everything and tell me what changed", use `make update-all`.

## 7) Operational Notes

- **Tailscale must be up** on your laptop — same requirement as every other Ansible-driven target in this repo.
- **Unreachable hosts are not retried.** Re-run `make update-all` once the host is back; the new log will overwrite the previous same-day file.
- **Same-day re-runs overwrite the log** because the filename is `apt-upgrade-YYYY-MM-DD.log`. If you need both runs archived, rename the existing file before re-running.
- **No reboot handling.** If a kernel or libc upgrade leaves `/var/run/reboot-required`, that is visible in the package list but the host is not rebooted. Reboot manually or run the bootstrap upgrade play (which has the reboot logic) for that host.
- **Parallelism** comes from Ansible's default forks setting. Ten hosts fit well within default forks, so play 1 effectively runs in parallel across the fleet.
