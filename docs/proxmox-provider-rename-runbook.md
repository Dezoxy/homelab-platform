# bpg/proxmox provider rename migration runbook

The bpg/proxmox provider is renaming every resource and data source from
`proxmox_virtual_environment_*` to a short `proxmox_*` form
([ADR-007](https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/adr/007-resource-rename-migration.md)).
Each release adds aliases for one or more resource families, then deprecates
the long names. v1.0 will drop the long names entirely.

## Migration status (this repo)

| Resource family | Migrated? | Stacks | Migration commit |
|---|---|---|---|
| `proxmox_virtual_environment_hardware_mapping_pci` → `proxmox_hardware_mapping_pci` | ✅ | `01-media-vm` | (see git log around `Rename hardware-mapping resources to drop deprecated provider type names`) |
| `proxmox_virtual_environment_hardware_mapping_dir` → `proxmox_hardware_mapping_dir` | ✅ | `01-media-vm` | same commit |
| `data.proxmox_virtual_environment_file` → `data.proxmox_file` | ✅ | all LXC stacks via the module | `Rename deprecated proxmox_virtual_environment_file data source` |
| `proxmox_virtual_environment_file` (resource form, hook scripts) | ⏳ pending — used in `01-media-vm` and `01-backup-lxc` with `count = 0` today; rename when those toggles flip on |
| `proxmox_virtual_environment_container` → `proxmox_container` | ❌ pending — alias not yet shipped in upstream provider as of v0.106. Affects all 10 LXC stacks. |
| `proxmox_virtual_environment_vm` → `proxmox_vm` | ⏳ alias exists; no deprecation warning yet — migrate when the deprecation lands |

## When to migrate

You'll know an alias has landed and the long name has been deprecated when
`make terraform-plan-all` starts printing:

```
Warning: Deprecated
Use "proxmox_<short_name>" instead. This resource / data source will be
removed in v1.0.
```

That warning is the trigger. Until then, don't pre-emptively rename — the
short name doesn't exist yet and `terraform plan` will fail with
"Invalid resource type".

## How to migrate (per resource family)

The shape mirrors what we did for `proxmox_hardware_mapping_*`. Pick one
stack first to validate, then loop over the rest.

### 1. Code: rename the resource type and all references

Edit the stack's `.tf` (or the shared module if it's used everywhere — that's
the case for `proxmox_virtual_environment_container` in
`modules/proxmox-lxc/main.tf`):

```diff
- resource "proxmox_virtual_environment_container" "this" {
+ resource "proxmox_container" "this" {
```

Search-and-replace any references too (look for the old type name in `for`
expressions, output values, and other resources' attribute references).

### 2. Add `removed` + `import` blocks for state migration

`moved` blocks can't span resource types; `removed` (with
`destroy = false`) + `import` is the only way to move state addresses
across types declaratively.

For a single resource:

```hcl
removed {
  from = proxmox_virtual_environment_container.this
  lifecycle {
    destroy = false
  }
}

import {
  to = proxmox_container.this
  id = "<vmid>"
}
```

For a `for_each` resource, the `removed` block uses the BARE address (no key);
add one `import` block per key:

```hcl
removed {
  from = proxmox_virtual_environment_hardware_mapping_dir.virtiofs
  lifecycle { destroy = false }
}

import {
  to = proxmox_hardware_mapping_dir.virtiofs["homelab-appdata"]
  id = "homelab-appdata"
}

import {
  to = proxmox_hardware_mapping_dir.virtiofs["homelab-media"]
  id = "homelab-media"
}
```

### 3. Verify locally

```bash
make terraform-plan TARGET=<stack>
```

Expected output:

```
Plan: <N> to import, 0 to add, 0 to change, 0 to destroy.
```

Zero `change` / `destroy` lines for actual infrastructure. The "Some objects
will no longer be managed by Terraform" warning is misleading-sounding but
correct — those addresses are state-only renames, not real removals.

### 4. Apply

Either:

```bash
make deploy TARGET=<stack> MODE=infra
```

…or trigger the workflow:

```bash
gh workflow run "Platform / Deploy" --repo Dezoxy/toom-platform-homelab \
  -f deployment_mode="Infrastructure only" \
  -f target_<stack>=true
```

Apply should end with:

```
Apply complete! Resources: <N> imported, 0 added, 0 changed, 0 destroyed.
```

### 5. Cleanup commit

`import` blocks complain on subsequent plans once the target is in state.
After the apply succeeds, push a follow-up commit deleting the `removed` and
`import` blocks (the type-rename in code stays; only the migration blocks
go away).

## LXC-family specifics (when the alias eventually lands)

The container resource lives in the shared module
`modules/proxmox-lxc/main.tf`, so renaming it there changes the resource
type for **all 10 LXC stacks at once**. The `removed`/`import` blocks
have to live per-stack though, since each stack has its own state file in
HCP Terraform.

Order of operations:

1. Rename the type in `modules/proxmox-lxc/main.tf` only.
2. Run `make terraform-plan-all` — every stack will fail with "old type
   missing in state, new type missing in code/state" (essentially: it
   wants to destroy + create the LXC). Don't apply.
3. Add `removed`/`import` blocks to each of the 10 stacks' `main.tf`:

   ```hcl
   removed {
     from = module.lxc.proxmox_virtual_environment_container.this
     lifecycle { destroy = false }
   }
   import {
     to = module.lxc.proxmox_container.this
     id = "<vmid>"   # the per-stack vmid; see terraform.tfvars
   }
   ```

4. Re-run `make terraform-plan-all`. Each stack should now report
   `Plan: 1 to import, 0 to add, 0 to change, 0 to destroy.`
5. Apply each stack via `make deploy TARGET=<stack> MODE=infra` (or
   one workflow_dispatch with all targets selected). Sequential is safer
   than parallel here.
6. After all 10 succeed, remove the `removed`/`import` blocks in a single
   cleanup commit.

## Spotting deprecation warnings proactively

The fastest signal is the periodic `make terraform-plan-all` output. CI's
plan workflow also surfaces them. Subscribe to bpg/proxmox releases on
GitHub for an even earlier heads-up — each release that adds aliases or
deprecations is in the changelog under "Features" / "Miscellaneous".
