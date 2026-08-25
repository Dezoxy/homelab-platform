# Lessons

- When the Proxmox provider reports "failed to authenticate" with `connect: network is unreachable`, the real issue is runner-to-Proxmox connectivity; explicit API reachability checks and failure-time `tailscale status` output make that obvious.
- The Proxmox provider can report `error waiting for VM start ... unexpected status` even when `qmstart` actually succeeded; proactively untainting VM resources avoids destroy/recreate loops on the next apply.
- When Proxmox returns an `unexpected status` from `qmstart`, a same-job retry works better if the pipeline waits for task metadata to settle; a very short retry window can miss the eventual success and force a second manual run.
- The HCP workspace name in a Terraform `cloud` backend is authoritative; renaming it in the repo causes `terraform init` to create a new workspace unless the existing HCP workspace is renamed to match first.
- Repo-managed app source that is only shipped by Ansible belongs under `ansible/files/`; keeping it there avoids stale top-level folders like `services/` and makes deploy dependencies easier to trace.
- If a CLI config references env vars, systemd `EnvironmentFile=` is not enough for human shells; interactive shell startup files need to source the same env file or the CLI will fail even though the service works.
- For remote shells, `.bashrc` alone is not enough; login shells and zsh sessions need the same env sourcing in `.profile` or `.zshrc` to make CLI tools behave like the systemd service.
- Sourcing a `KEY=VALUE` env file is not enough for child processes; shell startup snippets need `set -a` or explicit `export` so CLI tools inherit the variables, not just the current shell.
- Renovate's built-in managers cover standard manifests (`package.json`, `Dockerfile`, Terraform, Packer, GitHub Action `uses:`), but versions embedded in arbitrary YAML vars or workflow `with.version` inputs need explicit custom regex managers or they will silently drift.
- Codex release downloads use GitHub release tags like `rust-v0.111.0`, not plain semver; Renovate needs a dedicated regex manager and regex versioning so Ansible pins can be bumped without dropping the `rust-v` prefix.
- Broad Docker-image regex managers for YAML can accidentally match reverse-proxy URLs like `http://host:port`; nested image matchers should explicitly exclude URL schemes so Renovate doesn't query Docker registries for internal service endpoints.

- Deploying `MODE=config` to a tiny (512MB/1-core) LXC (01-reverse-proxy-lxc,
  01-dns-lxc) runs the FULL bootstrap chain incl. observability-agent apt
  work, which can starve the container into a state where TCP connects but
  SSH/TLS/apt handshakes hang (kernel answers SYN, userspace too starved to
  finish) — took down homelab ingress once. For config-only changes (a
  Traefik route, an AdGuard rewrite) run ONLY the relevant role via a
  temporary role-only play + ANSIBLE_PLAY override (+ ANSIBLE_TARGET_SECRETS=true
  if the role needs creds), not a full `make deploy MODE=config`. Recovery
  from the starved state was a container reboot (pct reboot <vmid> on pve).
- A new guest needs its DNS record too: after adding it to inventory, redeploy
  the adguard_home role on 01-dns-lxc so AdGuard regenerates the inventory-derived
  <host>.home.arpa rewrite — else Traefik gets NXDOMAIN on the backend hostname
  and returns 502 (backend is fine by IP).
