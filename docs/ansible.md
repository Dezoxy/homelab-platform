# Ansible Deployment Reference

Service playbooks under `ansible/playbooks/services/` contain their
target-specific deployment sequence, including any root filesystem, package,
and observability work that is appropriate for a full deployment. Operator
deployments must go through the Makefile or the GitHub Actions deploy workflow
so secrets, target limiting, and deployment modes are handled consistently.

## Supported Local Deployment

Choose a deployment mode explicitly:

```bash
make deploy TARGET=01-media-vm MODE=config
make deploy TARGET=01-media-vm MODE=infra
make deploy TARGET=01-media-vm MODE=full
make deploy-check TARGET=01-media-vm
```

| Mode | Terraform | Rootfs expansion and package upgrades | Service configuration |
|---|---:|---:|---:|
| `config` | No | No | Yes |
| `infra` | Yes | No | No |
| `full` | Yes | Yes | Yes |

`MODE` is mandatory. With `MODE=full`, use `SKIP_UPDATES=true` or
`SKIP_EXPAND=true` only when deliberately suppressing part of the full
reconciliation.

`deploy-check` runs the **same** `scripts/ci/run_ansible.sh` as `make deploy`,
with `ANSIBLE_CHECK_MODE=true` adding `--check --diff`. That parity is the point:
an earlier version built its own `ansible-playbook` command with four `-e` flags
where the script injects twenty-nine, so dry runs failed on secrets a real
deploy supplies (#823).

Two things are deliberately **not** previewable, and say so rather than failing:
the Alloy and Traefik installs fetch and unpack a binary, which check mode
cannot do. They skip as a unit and report what they would have done. Read-only
probes across the roles carry `check_mode: false` so they run in both modes —
without that, a skipped read leaves later tasks consuming a register that has no
value, and the error blames the host instead of the dry run.

## Local Fleet Deployment

```bash
make deploy-all MODE=config
make deploy-all MODE=full
```

`deploy-all` runs the same target-scoped deployment path sequentially across
all hosts.

## CI Deployment

Use the `Platform / Deploy` GitHub Actions workflow. Select both targets and a
deployment mode explicitly. The workflow runs one target-scoped job per
selected host through `scripts/ci/run_ansible.sh`.

## Retired Site-Wide Playbook

`ansible/playbooks/site.yml` is retained only as a fail-fast guard for old
commands. It must not perform deployments: individual service playbooks now
include target-scoped common sequencing, so composing them into one raw
site-wide execution would repeat work across the fleet.

## Direct Ansible Diagnostics

For syntax inspection or tightly scoped diagnostics, always use the service
playbook path and `--limit`:

```bash
export ANSIBLE_CONFIG=ansible/ansible.cfg
ansible-playbook --syntax-check -i ansible/inventory.ini ansible/playbooks/services/01-media-vm.yml
ansible-playbook --check --diff -i ansible/inventory.ini \
  ansible/playbooks/services/01-media-vm.yml --limit 01-media-vm \
  -e rootfs_expand_enabled=false -e auto_upgrade=false
```

For actual deployments, prefer `make deploy` because it loads secrets from
Azure Key Vault and applies the expected SSH and target handling.
