# Incident: Platform Deploy Failures (`01-backup-lxc` and `01-agent-vm`)

## Summary

`Platform / Deploy (Full deploy)` failed on March 24, 2026 for two selected targets:

- `01-backup-lxc`
- `01-agent-vm`

The failures were independent:

- `01-backup-lxc` failed in Terraform because the Proxmox datastore used for hook snippets did not support `snippets`.
- `01-agent-vm` failed in Ansible because the playbook assumed an OpenClaw npm package path that did not match the actual installed package state on the host.

Relevant runs:

- Run `#284`: `https://github.com/Dezoxy/toom-platform-homelab/actions/runs/23480403790`
- Run `#285`: `https://github.com/Dezoxy/toom-platform-homelab/actions/runs/23480505088`

## Impact

- `01-backup-lxc` deployment stopped during Terraform apply before Ansible ran.
- `01-agent-vm` infrastructure finished, but application configuration stopped during the OpenClaw OTEL patch step.
- A rerun with `force_replace=true` for `01-backup-lxc` destroyed the existing CT before failing on the same snippet upload problem.

## Symptoms Observed

### `01-backup-lxc`

- Terraform warned:
  - datastore `local` does not support `snippets`
- Terraform then failed while uploading:
  - `/var/lib/vz/snippets/01-backup-lxc-pre-start-hook.sh`

### `01-agent-vm`

- Ansible failed in:
  - `Patch bundled OpenClaw diagnostics OTEL plugin source`
- The task tried to read:
  - `/usr/lib/node_modules/openclaw/extensions/diagnostics-otel/src/service.ts`
- The file was not found on the deployed host.

## Root Cause

### 1) Proxmox snippet storage assumption in backup/media Terraform

The backup LXC module enabled a Proxmox pre-start hook by default and assumed the configured datastore could store hook snippets.

That assumption was not valid on the deployed node:

- the configured datastore reported support for `backup`, `import`, `iso`, and `vztmpl`
- it did not support `snippets`

Because the hook resource was created before attaching it to the container, Terraform failed before completing the deploy.

The same default hook-guard pattern also existed in the media VM Terraform module, so it was a latent failure there as well.

### 2) Brittle OpenClaw package path resolution in the agent playbook

The agent playbook resolved:

- the OpenClaw binary via `command -v openclaw`
- the OpenClaw package directory via `$(npm root -g)/openclaw`

That made the OTEL patch step depend on a derived npm path instead of the actual installed package path.

For this incident, the derived package path did not contain the expected plugin source file, so the playbook failed before enabling the bundled diagnostics plugin.

## Remediation Applied

### Terraform

The Proxmox pre-start mount guard is now opt-in instead of enabled by default for the affected modules:

- `infra-proxmox/terraform/01-backup-lxc/variables.tf`
- `infra-proxmox/terraform/01-media-vm/variables.tf`
- `infra-proxmox/terraform/01-media-vm/terraform.tfvars.example`

Behavior after the change:

- deploys no longer assume snippet-capable Proxmox storage
- the hook guard can still be enabled explicitly later
- if re-enabled, the hook datastore must point at storage with `snippets` enabled

### Ansible

The agent playbook now:

- resolves the actual installed OpenClaw package path with:
  - `npm ls -g openclaw --parseable --depth=0`
- checks whether the bundled diagnostics OTEL source file exists
- force-reinstalls `openclaw@{{ openclaw_version }}` when that source file is missing
- re-resolves the package path after repair
- asserts the OTEL plugin source exists before patching it

Changed file:

- `ansible/playbooks/services/01-agent-vm.yml`

## Validation

The repo changes were validated locally with:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook --syntax-check -i ansible/inventory.ini ansible/playbooks/services/01-agent-vm.yml
terraform -chdir=infra-proxmox/terraform/01-backup-lxc init -backend=false -input=false
terraform -chdir=infra-proxmox/terraform/01-backup-lxc validate
terraform -chdir=infra-proxmox/terraform/01-media-vm init -backend=false -input=false
terraform -chdir=infra-proxmox/terraform/01-media-vm validate
```

## Rerun Plan

Re-run `Platform / Deploy (Full deploy)` for:

- `01-backup-lxc`
- `01-agent-vm`

Expected behavior:

- `01-backup-lxc` should no longer try to upload a Proxmox snippet by default
- `01-agent-vm` should either find the correct OpenClaw package path or self-repair the install before patching the OTEL plugin

## Follow-Up

- If pre-start mount guards are still desired for `01-backup-lxc` or `01-media-vm`, explicitly enable them and move the hook datastore to Proxmox storage configured with `snippets`.
- If OpenClaw install location should be deterministic long term, consider standardizing npm global prefix handling instead of mixing runtime path discovery with package-tree discovery.
