# 01-code-lxc

VS Code in the browser, plus the `claude` and `codex` CLIs, reached from any
device at **`code.example.com`** / **`code.example.net`**.

## Why this and not a Windows desktop

Both were built on 2026-08-25, in that order, and the comparison is the whole
justification for this guest:

| | Windows 11 VM + Guacamole | code-server LXC |
|---|---|---|
| Host memory | **8192 MB reserved**, always | ~1 GB of a 4096 MB **ceiling** |
| Reclaimable | only via balloon, above 80% host usage | yes — a container costs what it touches |
| On a phone or tablet | streams pixels; miserable | renders real DOM; genuinely usable |
| Guests needed | 2 (desktop + gateway) | 1 |

The Windows VM pushed a 31.8 GB host into swap and was retired the same day.
The role header that argued against it had been deleted a few hours earlier,
with `01-agent-lxc`, and turned out to be right.

## Persistence is the point

`/srv/appdata/code` is a Terraform bind mount from the Proxmox host, and
everything durable lives there:

```
/srv/appdata/code/code-server/user-data     settings, open editors
/srv/appdata/code/code-server/extensions    installed plugins
/srv/appdata/code/claude                    claude CLI auth
/srv/appdata/code/codex                     codex CLI auth
```

Two consequences worth stating:

- **A rebuild of this container loses nothing.** The rootfs holds only the OS,
  node, and the code-server package.
- **It is backed up with no backup-side change.** `01-backup-lxc`'s restic job
  already walks `/srv/appdata`; this tree simply appears inside it.

`roles/agent_cli` asserts the mount exists before writing. Without that check a
missing bind mount would silently create a plain directory on the rootfs, and
the auth state would vanish on the next rebuild — the exact failure the mount
exists to prevent.

### Why the container is privileged

Like `01-torrent-lxc` and `01-observability-lxc`, and for the same reason: an
unprivileged container shifts uids, so files written under `/srv/appdata` end
up owned by a high-numbered host uid the restic job cannot read cleanly.
`01-guacamole-lxc` could stay unprivileged precisely because it had no bind
mount.

One cosmetic consequence: uid 1000 is `toomhorvath` inside the container and
`ansible` on pve, so `ls` on the host shows a different owner name for the same
numeric uid. Nothing is wrong; the restic job runs as root and reads it either
way.

## Authentication

Two independent gates:

1. **Cloudflare Access** on the hostname — inherited from the wildcard apps
   (`allow-tom-only`, then `block-everyone-else`), so there is no per-app wiring.
2. **code-server's own password**, from Key Vault `code-server-password`
   (folder `agent`, env `CODE_SERVER_PASSWORD`).

The second is not redundant: Access guards the *public route*, while the port
is reachable from anywhere on the LAN. The credential is passed via an
`EnvironmentFile` at mode 0600 rather than argv, so `ps` does not expose it.

The `agent` folder was deliberately retained when `01-agent-lxc` was retired in
#793 — this reuses that one credential rather than minting a second copy free to
drift from it.

## Cloning and working on repositories

Repositories live in **`/srv/appdata/code/projects`**, which code-server opens
by default, so a fresh session lands in the workspace rather than an empty
window.

That location is deliberate. `$HOME` is `/home/toomhorvath` on the container
**rootfs**, so a clone there would be lost on a rebuild and never reach restic.
Under the bind mount, uncommitted work and untracked files — the parts a git
remote does not hold — are backed up.

**Public repos** work now: `Ctrl+Shift+P` → *Git: Clone*, or from the
integrated terminal:

```bash
cd /srv/appdata/code/projects && git clone https://github.com/owner/repo.git
```

**Private repos** work over SSH. The role provisions the *configuration* —
`~/.ssh/config` with an `IdentitiesOnly` entry for `github.com`, and that host's
public key pinned into `~/.ssh/known_hosts` — but deliberately **not the private
key**, which comes from Key Vault instead:

```bash
az login       # once per container
make ssh-keys  # writes ~/.ssh/toomhorvath and ~/.ssh/runner
```

The same key is the fleet identity, so this one step also unblocks `make
update-all` (see below). Clone with the SSH remote:

```bash
cd /srv/appdata/code/projects && git clone git@github.com:owner/repo.git
```

Two consequences of that split worth knowing:

- **The key is on the container rootfs, not the bind mount**, so a rebuild
  loses it. That is intended: re-run `make ssh-keys` rather than persisting a
  private key into backups. The config and pinned host key come back with the
  deploy.
- **`IdentitiesOnly yes` is load-bearing.** OpenSSH only offers identities with
  default filenames (`id_rsa`, `id_ed25519`, …), and `toomhorvath` is not one —
  so without the config entry a clone fails with *"Permission denied
  (publickey)"* even though the key is sitting right there.

On a **brand-new** container there is a bootstrap loop: `make ssh-keys` needs
this repo, and cloning this repo needs the key. Break it once, without the
repo:

```bash
az login
install -d -m 700 ~/.ssh
az keyvault secret show --vault-name kv-homelab-prod --name ssh-toomhorvath-ssh-private-key-b64 --query value -o tsv | base64 -d > ~/.ssh/toomhorvath
chmod 600 ~/.ssh/toomhorvath
```

Then clone over SSH and let `make ssh-keys` take over.

Identity is seeded by the role (`user.name`, `user.email`,
`init.defaultBranch=main`) into `/srv/appdata/code/gitconfig`, symlinked to
`~/.gitconfig`. It uses the same noreply address this repo's commits already
use, so authorship stays consistent. Without it the first `git commit` fails
with *"Please tell me who you are"* — a poor way to find out the editor is only
half set up.

### Why "Clone Repository" was missing

Because `git` was not installed. VS Code's built-in Git extension **hides its
entire UI** — including the welcome screen's clone button — when it cannot find
a git binary. The editor looks like it simply lacks the feature rather than
like something is absent, which is why the role now installs git,
openssh-client, ca-certificates, curl and less explicitly.

## Running the repo's own tooling

`make lint`, `make ci` and `make deploy` work from this guest as well as from
the Mac. `roles/dev_toolchain` installs make, Python 3.13, Terraform, the Azure
CLI and pre-commit.

Two things that are not obvious and cost time to find:

**Ubuntu 26.04 ships Python 3.14, and the Makefile refuses it.** Local tooling
pins require `>=3.12,<3.14` because checkov's `google-re2` is not reliably
wheel-backed on 3.14+, and the archive has no older interpreter. 3.13 comes
from deadsnakes, which does publish for `resolute`. The Makefile finds it by
name, so no `PYTHON=` override is needed.

**The image ships only `C`, `C.utf8` and `POSIX` locales.** Ansible aborts with
*"could not initialize the preferred locale"*, which kills `make setup` before
it installs anything. The role generates `en_US.UTF-8` and sets it as the
system default.

Terraform's version is read from `scripts/ci/versions.sh` on the controller at
deploy time rather than pinned again in the role, so CI and this guest cannot
disagree about which Terraform the repo targets.

`packer` and `tflint` are deliberately **not** installed by the role —
`make install-tools` already fetches both into `.local/bin` at the pinned
versions, and a second system-wide copy would only create ambiguity about which
one a lint run used.

### What an `az login` here grants

Worth being explicit. `AZURE_KEYVAULT_FOLDER` is a **JMESPath filter applied to
the result of a full `az keyvault secret list`** — it scopes what a deploy
*asks for*, not what the session *may read*. Any session on this box can read
every secret the signed-in identity is entitled to.

That is accepted deliberately for a box behind Cloudflare Access plus a
password. If it stops being acceptable, the fix is a **service principal with a
Key Vault access policy scoped to the folders this guest needs** — not a
tighter environment variable.

Note also that Ansible deploys additionally need `~/.ssh/toomhorvath` present
to build the attested `known_hosts` through pinned pve — `make deploy` reaches
guests through Ansible, but `make update-all` first attests each host key over
plain `ssh -i`. `make ssh-keys` writes that key from the vault's `ssh` folder.

It is a separate, explicit step rather than a dependency of `update-all`,
because it **overwrites**: folding it in would rewrite the keys on every
machine that runs maintenance, including the Mac where those keys legitimately
live on disk.

## Extensions

Two mechanisms, because code-server resolves ids against **Open VSX**, not
Microsoft's marketplace.

**On Open VSX** — declare the id in `host_vars/01-code-lxc/vars.yml`:

```yaml
code_server_extensions:
  - anthropic.claude-code
  - openai.chatgpt
```

Fully reproducible from this repo: a rebuilt container reinstalls them with no
backup needed.

**Not on Open VSX** — drop the `.vsix` in the drop directory and deploy:

```bash
scp thing.vsix toomhorvath@192.168.1.239:/tmp/
ssh toomhorvath@192.168.1.239 'sudo mv /tmp/thing.vsix /srv/appdata/code/code-server/vsix/'
make deploy TARGET=01-code-lxc MODE=config
```

That directory is on the appdata bind mount, so the files are backed up and a
rebuild restores them. **The trade-off, stated plainly: these are reproducible
from BACKUP, not from source.** They are megabytes of binary — over the repo's
500 KB large-file limit — and typically have no stable URL to pin.

Currently `khaled.vscode-openrouter-extension`, which has neither an Open VSX
listing nor a findable upstream release.

### Two things that will bite

**Always pass `--extensions-dir` and `--user-data-dir`** when calling the
code-server CLI by hand. It defaults to `~/.local/share/code-server`, so
without them it prints *"successfully installed"* into a directory the running
service never reads — a clean success and an extension that silently never
appears.

**The role uses `runuser`, not Ansible's `become_user`.** Becoming an
unprivileged user from root needs ACL support this container lacks; it fails
with `chmod: invalid operator`. `runuser` drops privilege for the single
command and sidesteps the mechanism entirely.

Idempotence comes from deriving the extension id from the `.vsix` filename
(`publisher.name-version.vsix`) and comparing against `--list-extensions`.
Verified in both directions: skipped when present, reinstalled when removed.

## Operating it

```bash
make deploy TARGET=01-code-lxc MODE=config
```

Idempotent — `changed=0` on a second consecutive run.

Boot order 55, autostarted, after the app stacks and before the manual-start
backup container. The mount guard (`scripts/ops/pve-mount-guard.sh`) has VMID
176 requiring `/srv/appdata`, so the container will not start against a missing
mount.

## Versions

Three pins, all tracked by Renovate custom managers:

| | Where |
|---|---|
| `code_server_version` | `roles/code_server/defaults/main.yml` |
| `agent_claude_version` | `roles/agent_cli/defaults/main.yml` |
| `agent_codex_version` | `roles/agent_cli/defaults/main.yml` |

The CLIs are installed at pinned versions rather than by bare `npm i -g`, so a
deploy cannot silently install whatever shipped that morning.
