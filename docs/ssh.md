# SSH Host Trust And Access

Deployment and maintenance connections use a Proxmox-attested trust model:

- `ansible/ssh_known_hosts` permanently pins only the `pve` SSH host key.
- `ansible/proxmox_guest_ssh_attestation.json` maps each guest target to its
  reviewed Proxmox VMID and type.
- `scripts/ci/build_attested_ssh_known_hosts.py` connects to verified `pve`,
  checks the selected VMID has the expected target name, reads its public host
  key locally through Proxmox, and writes a temporary `known_hosts` file.
- Ansible connects directly to the guest with strict host-key checking against
  that temporary file.

For LXCs, Proxmox reads `/etc/ssh/ssh_host_ed25519_key.pub` using `pct exec`.
For the VMs it uses the QEMU Guest Agent via `qm guest exec` — all three
(`01-media-vm`, `01-myapps-vm`, `01-unifi-vm`) run it with `agent_enabled = true`
in their Terraform stacks. All eleven guests are covered by the attestation map.

## Direct Proxmox Access

Connect to `pve` using the permanent trust anchor:

```bash
ssh -i ~/.ssh/toomhorvath \
  -o UserKnownHostsFile=ansible/ssh_known_hosts \
  -o StrictHostKeyChecking=yes \
  toomhorvath@192.168.1.239
```

## Direct Guest Access

Generate temporary guest trust through pinned `pve`, then connect directly:

```bash
trust_file="$(mktemp)"
python3 scripts/ci/build_attested_ssh_known_hosts.py \
  --target 01-media-vm \
  --output "${trust_file}"

ssh -i ~/.ssh/toomhorvath \
  -o UserKnownHostsFile="${trust_file}" \
  -o StrictHostKeyChecking=yes \
  toomhorvath@192.168.1.70

rm -f "${trust_file}"
```

Provisioning public keys in `keys/` identify allowed users. They are separate
from server host identity keys.

## Getting The Private Keys Onto A Machine

Everything above assumes `~/.ssh/toomhorvath` (and `~/.ssh/runner` for LXC
targets) already exist. On a machine that has neither — a fresh clone, or
`01-code-lxc` — they come from Key Vault rather than being copied by hand:

```bash
az login       # once per machine
make ssh-keys  # writes ~/.ssh/toomhorvath and ~/.ssh/runner
```

`make ssh-keys` runs `scripts/ci/prepare_ssh_keys.sh`, the same script the
GitHub Actions workflows use, scoped to the vault's `ssh` folder. It also
derives `keys/toomhorvath.pub` and `keys/runner.pub`, which the bootstrap play
reads.

Deliberately **not** part of `make bootstrap`: it overwrites, and on a machine
that already holds these keys that would rewrite them from the vault.

Note the split this closes: `make deploy` reaches guests through Ansible, but
`make update-all` first attests each host key over plain `ssh -i`, so a box can
be able to deploy and still fail maintenance with
`Identity file ~/.ssh/toomhorvath not accessible`.

On a brand-new container there is a bootstrap loop — `make ssh-keys` needs this
repo, and cloning a private repo needs the key. Break it once without the repo:

```bash
az login
install -d -m 700 ~/.ssh
az keyvault secret show --vault-name kv-homelab-prod \
  --name ssh-toomhorvath-ssh-private-key-b64 --query value -o tsv \
  | base64 -d > ~/.ssh/toomhorvath
chmod 600 ~/.ssh/toomhorvath
```

## Guest Create Or Rebuild

There is no manual guest fingerprint step. Terraform can create or replace a
guest, then deployment regenerates its SSH trust through pinned `pve` before
running Ansible. If the IP answers with any other key than the key Proxmox
reported for the selected VMID, SSH fails.

When adding a new guest or changing its VMID, update
`ansible/proxmox_guest_ssh_attestation.json` alongside its Terraform and
inventory definition.

The controlled media rebuild flow also regenerates guest trust
automatically before configuration and restore work.

## Replace Or Reinstall Proxmox

`pve` is the root of trust and cannot be automatically re-enrolled from the
same network it authenticates. Prefer restoring its SSH private host keys from
an encrypted disaster-recovery backup. If it has a new key:

1. From the local Proxmox console, display its Ed25519 fingerprint:

   ```bash
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
   ```

2. Observe the network-presented key without trusting it:

   ```bash
   scripts/setup/enroll-ssh-host-key.sh pve
   ```

3. Only when those fingerprints match, update the committed root key:

   ```bash
   scripts/setup/enroll-ssh-host-key.sh \
     --verified 'SHA256:<fingerprint-read-from-pve-console>' pve
   python3 scripts/ci/validate_ssh_known_hosts.py
   ```

4. Review and commit `ansible/ssh_known_hosts` before running deployments.

If `pve` is compromised, guest attestation is no longer trustworthy. This is
consistent with its existing authority to create, replace, and console into
every managed VM/LXC.
