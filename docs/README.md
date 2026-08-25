# Homelab Documentation

The top-level [README](../README.md) is the operator entry point for setup and
routine commands. This index points to the canonical architecture documents,
runbooks, service references, and incident records.

## Start Here

- [ONBOARDING.md](ONBOARDING.md) - guided tour of the repository and its automation layers
- [platform.md](platform.md) - current architecture, network layout, nodes, and storage model
- [future-plan.md](future-plan.md) - remaining repository improvement roadmap and completed delivery record

## Deploy And Operate

- [terraform.md](terraform.md) - Terraform provisioning order, prerequisites, and state
- [base-images.md](base-images.md) - pinned Proxmox LXC and VM image workflow
- [ansible.md](ansible.md) - supported Ansible deployment paths and diagnostics
- [ci-workflows.md](ci-workflows.md) - local and GitHub Actions workflow map
- [validation-checks.md](validation-checks.md) - every local hook and pull-request validation check
- [github-secrets.md](github-secrets.md) - GitHub variables and Azure Key Vault runtime secret reference
- [ssh.md](ssh.md) - SSH trust model, access commands, and Proxmox replacement procedure
- [apt-upgrade-working-method.md](apt-upgrade-working-method.md) - fleet package-maintenance procedure
- [proxmox-boot-shutdown-order.md](proxmox-boot-shutdown-order.md) - guest startup sequencing and verification
- [proxmox-provider-rename-runbook.md](proxmox-provider-rename-runbook.md) - Terraform provider resource migration
- [pve-fleet-cleanup.md](pve-fleet-cleanup.md) - Proxmox host cleanup timer and operations

## Service Runbooks

- [backup-lxc.md](backup-lxc.md) - Time Machine share, offsite backup, and restore operations
- [code-server.md](code-server.md) - VS Code in the browser on `01-code-lxc`
- [compose-vm.md](compose-vm.md) - Docker Compose and VirtIO-FS operations for `01-media-vm`
- [dns-rewrites.md](dns-rewrites.md) - AdGuard DNS rewrite rules
- [observability-working-method.md](observability-working-method.md) - telemetry architecture and alerting thresholds
- [unifi.md](unifi.md) - self-hosted UniFi controller and remote-site AP adoption

## Reference

- [current-device-IDs.md](current-device-IDs.md) - Proxmox host hardware snapshot

## Incidents

- [incidents/2026-02-23-dns-ipv6-upstream-latency.md](incidents/2026-02-23-dns-ipv6-upstream-latency.md) - AdGuard upstream latency caused by IPv6/RA configuration
- [incidents/2026-03-24-platform-deploy-backup-lxc-agent-vm.md](incidents/2026-03-24-platform-deploy-backup-lxc-agent-vm.md) - deployment failures for backup and agent targets
- [incidents/2026-04-03-antigravity-pet-missing-binary.md](incidents/2026-04-03-antigravity-pet-missing-binary.md) - Antigravity IDE Python extension crash
