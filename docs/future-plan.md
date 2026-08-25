# Repository Improvement Roadmap

Status: Active
Updated: 2026-05-26

## Objective

Keep the repository simple and safe to operate without redesigning the
platform. Terraform provisioning, Ansible configuration, image builds,
workflows, and runbooks remain separate because they have distinct operational
responsibilities.

## Decisions To Preserve

- Keep one Terraform Cloud workspace per guest to limit infrastructure blast
  radius and allow independent recovery.
- Keep shared Terraform modules plus host-specific stacks because hosts have
  real storage, passthrough, and recovery differences.
- Keep Ansible roles as the deployment configuration layer.
- Keep the Makefile as the supported local operator entry point unless it
  becomes a demonstrated maintenance problem.

## Completed Deliveries

| Date | Work | Result |
| --- | --- | --- |
| 2026-05-25 | Explicit deployment modes ([#379](https://github.com/Dezoxy/toom-platform-homelab/pull/379)) | Local and CI deployments require `config`, `infra`, or `full`; the retired site-wide playbook cannot accidentally repeat fleet work. |
| 2026-05-26 | Complete Terraform CI coverage ([#379](https://github.com/Dezoxy/toom-platform-homelab/pull/379)) | Terraform lint and read-only plan coverage derive from managed stack directories, including `01-infisical-lxc`. |
| 2026-05-26 | Strict SSH trust and Proxmox guest attestation ([#378](https://github.com/Dezoxy/toom-platform-homelab/pull/378), [#380](https://github.com/Dezoxy/toom-platform-homelab/pull/380)) | Deployments pin `pve`, generate guest trust through its verified identity, and no longer accept unauthenticated network key discovery. |
| 2026-05-26 | Documentation consolidation and generated-output cleanup ([#381](https://github.com/Dezoxy/toom-platform-homelab/pull/381)) | Canonical runbooks replace overlapping notes; incident records are grouped; local `.understand-anything` graph output is no longer tracked. |

## Should Improve

### 1. Decide The OpenClaw Role's Future — **done**

Resolved. `ansible/roles/openclaw` no longer exists; the role, its templates and
its telemetry surface went with the retirement of `01-agent-lxc`. Verified
2026-08-25: the only remaining mentions are in documentation, and they are
correct — `docs/observability-working-method.md` records the gateway as
deprecated and not deployed, and the incident record keeps its original wording
as a dated artefact.

One loose end, deliberately left: the vault still holds
`openclaw/OPENCLAW_TELEGRAM_BOT_TOKEN`. No target maps to that folder, so
nothing fetches it. Kept rather than purged, for the same reason the `agent`
folder was.
- If retained, wire it through a supported service playbook and document its
  deployment path.

Completion criterion: every significant role is either actively deployed or
clearly marked as staged work.

### 2. Add Target Consistency Validation

Problem: target membership is repeated across Terraform stacks, image
bindings, inventory generation, CI target scripts, maintenance workflows, and
attestation metadata. Terraform matrix coverage has been repaired, but a new
host can still be registered incompletely elsewhere.

Planned work:

- Add a CI validation script that compares the current target sources.
- Fail clearly when a Terraform stack, image binding, Ansible service
  playbook, attestation entry, or required workflow target is missing.
- Consider a single `config/hosts.yml` manifest only if validation shows the
  existing sources remain costly to maintain.

Trade-off: validation is lower risk than introducing a new
configuration-generation system immediately.

Completion criterion: adding or removing a host fails validation until all
required registration points agree.

### 3. Use Pinned Tool Versions Consistently (Completed 2026-05-26)

Problem: `scripts/ci/versions.sh` is intended as the version source of truth,
but maintenance workflows and local hooks previously hardcoded divergent
Ansible and Packer versions.

Implemented:

- Local Ansible/Checkov/Packer hooks consume Make-managed tools installed from
  `scripts/ci/versions.sh`.
- Maintenance workflows load Ansible and Tailscale pins from that file.
- Packer validation/build/deploy workflow paths consume the central Packer
  pin, and Renovate updates the source pin rather than workflow copies.

Completion criterion met: affected local and workflow runtime versions no
longer silently diverge from declared pins.

## Recommended Delivery Order

1. Target-consistency validation.
2. OpenClaw retirement or supported reintegration.

## Verification Expectations

Each implementation pull request should run the relevant subset of:

```bash
make ci
python3 scripts/setup/generate-inventory.py --dry-run
```

Changes affecting deploy or SSH trust must also include an exercised dry-run
or a documented reason that it cannot be run without changing live
infrastructure.
