# Homelab Onboarding

This is a navigation guide for a new operator or contributor. It intentionally
does not repeat the architecture inventory or individual runbooks; those have
canonical documents linked below.

## Reading Path

1. Read the top-level [README](../README.md) for setup, routine commands, and
   the current host inventory.
2. Read [platform.md](platform.md) for the canonical network, node, and
   storage model.
3. Use the [documentation index](README.md) to find the runbook for the
   service or operation you are changing.
4. For deploy work, read [ci-workflows.md](ci-workflows.md),
   [ansible.md](ansible.md), and [terraform.md](terraform.md).
5. For credentials or connectivity, read [github-secrets.md](github-secrets.md)
   and [ssh.md](ssh.md).

## Ownership Map

| Question | Canonical document | Code entry point |
| --- | --- | --- |
| What runs where? | [platform.md](platform.md) | [ansible/inventory.ini](../ansible/inventory.ini) |
| How do I deploy or plan changes? | [ci-workflows.md](ci-workflows.md) | [Makefile](../Makefile) |
| How is a guest created? | [terraform.md](terraform.md), [base-images.md](base-images.md) | [infra-proxmox/terraform](../infra-proxmox/terraform) |
| How is a service configured? | [ansible.md](ansible.md) | [ansible/playbooks/services](../ansible/playbooks/services) |
| How are runtime secrets supplied? | [github-secrets.md](github-secrets.md) | [.github/workflows](../.github/workflows) |
| How is SSH trust established? | [ssh.md](ssh.md) | [scripts/ci/build_attested_ssh_known_hosts.py](../scripts/ci/build_attested_ssh_known_hosts.py) |
| How do I operate a specific service? | [documentation index](README.md) | [ansible/roles](../ansible/roles) |

## Operating Rules

- Identify ownership before editing: Terraform creates guests; Ansible
  configures services; Packer supplies reusable base images.
- Use target-scoped deploy entry points. Local deployment requires an explicit
  mode: `make deploy TARGET=<host> MODE=config|infra|full`.
- Do not treat `ansible/playbooks/site.yml` as a deployment entry point; it is
  a retired fail-fast guard.
- Keep secrets in Azure Key Vault, never in tracked variable or template
  files.
- Preserve strict SSH verification: `pve` is the permanent root of trust and
  guest keys are attested through it at runtime.

## First Safe Commands

These commands inspect or validate without applying infrastructure changes:

```bash
make help
make ci
make terraform-plan TARGET=01-media-vm
make deploy-check TARGET=01-media-vm
```

`terraform-plan` requires Proxmox/Terraform credentials and network access.
`deploy-check` connects to the selected live guest and runs Ansible in check
mode.

`deploy-check` runs the same code path as a real deploy, so what it reports is
what a deploy would do. The Alloy and Traefik installs are the exception: they
fetch and unpack binaries, so check mode skips them and prints what they would
have installed.

## Trace One Host

For an unfamiliar target, follow the same narrow path:

1. Locate it in [platform.md](platform.md) and
   [ansible/inventory.ini](../ansible/inventory.ini).
2. Read its Terraform stack under
   [infra-proxmox/terraform](../infra-proxmox/terraform).
3. Read its target-scoped playbook under
   [ansible/playbooks/services](../ansible/playbooks/services).
4. Follow imported roles into [ansible/roles](../ansible/roles), including
   task, template, and embedded application files.
5. Verify locally with the narrowest relevant Make target before opening a
   pull request.

## High-Risk Areas

- Storage mount guards and media/backup replacements because a mistake can
  affect persisted data.
- Workflow changes that alter Terraform apply, guest replacement, or
  authentication behavior.
- Proxmox SSH root-key replacement because it changes the identity trusted by
  every local and CI guest deployment.
