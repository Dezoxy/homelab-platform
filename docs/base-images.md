# Proxmox Base Images

The repo pins guest base images in [`infra-images/catalog.json`](../infra-images/catalog.json).
The catalog has two parts:

- `images`: immutable LXC archive and VM template pins
- `targets`: the base image selected for each concrete VM or LXC stack

Both currently resolve to 26.04 only — `ubuntu-2604-lxc-v1` for the eight
containers and `ubuntu-2604-vm-v1` (template VMID 901, `tpl-ubuntu-2604-base`)
for the three VMs. The 24.04 pins were removed when the fleet was retiered.

The target binding is consumed by the resolver, image ensure playbook, and
Terraform apply/plan wrappers. Changing a target binding does not
release-upgrade a running guest. Review the Terraform plan before using a new
pin for an existing guest because rebuilding a guest from a new base image is a
destructive replacement path.

## Resolve A Target Pin

Use the resolver to inspect the catalog payload for one target:

```bash
python3 scripts/ci/resolve_image_pin.py --target 01-dns-lxc
python3 scripts/ci/resolve_image_pin.py --target 01-media-vm
```

The resolver validates that the target kind matches the selected image kind and
that VM Packer pins have the required build fields.

The same resolver can print the root Terraform variables declared by the target
stack:

```bash
python3 scripts/ci/resolve_image_pin.py \
  --target 01-dns-lxc \
  --format terraform-shell
```

`scripts/ci/terraform_apply.sh`, `scripts/dev/terraform_plan.sh`, and the
Terraform plan workflow evaluate that shell output before Terraform starts.
Terraform receives the pinned LXC archive datastore/name or VM template VMID as
`TF_VAR_*` input variables instead of workflow hardcoded image values.

## Ensure A Target Image

Proxmox host execution is kept in a dedicated inventory so guest-wide Ansible
maintenance plays do not target the hypervisor:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg \
ansible-playbook \
  -i ansible/inventory-proxmox.ini \
  ansible/playbooks/proxmox/ensure-target-image.yml \
  -e proxmox_image_target=01-dns-lxc
```

For an LXC pin, the playbook checks the selected `pveam` storage and downloads
the pinned `vztmpl` archive when it is missing.

For a VM pin, the playbook checks the pinned VMID and template name on Proxmox.
If the VM template is missing, it runs Packer on the Ansible controller from the
pinned Packer directory. The controller must already have `packer`, SSH access
to `pve`, and Packer SSH build variables:

The SSH connection to `pve` is verified against the pinned root-of-trust key in
`ansible/ssh_known_hosts`. The same trusted Proxmox connection is used to
attest guest SSH host keys after a guest is created or replaced.

```text
PKR_VAR_ssh_public_key
PKR_VAR_ssh_private_key_file
```

For Proxmox API credentials, the playbook accepts the repo's upstream
`/proxmox` Key Vault folder names:

```text
PROXMOX_API_URL
PROXMOX_TOKEN_ID
PROXMOX_TOKEN_SECRET
```

It also accepts the derived `PKR_VAR_proxmox_*` names written by:

```bash
bash scripts/ci/export_runtime_env.sh packer
```

The playbook passes catalog-pinned values such as VMID, template name, Proxmox
node, ISO URL, ISO checksum, and storage pools into Packer. If the pinned VMID
already exists but is not the pinned template name, the playbook fails before
Terraform can reuse the conflicting object.

## Deploy Flow

The local deploy path runs the image ensure step before Terraform for
infrastructure and full deploys:

```bash
make deploy TARGET=01-dns-lxc MODE=infra
make deploy TARGET=01-media-vm MODE=full
```

To build or verify a template **without** touching a workload:

```bash
make ensure-image IMAGE=ubuntu-2604-vm-v1
```

**`01-media-vm` is the exception to the flow above.** Its target binding already
points at `ubuntu-2604-vm-v1` while the running guest is still on the retired
24.04 template, so `MODE=full` there plans a destroy/create. That is blocked:
`scripts/ci/terraform_apply.sh` refuses any apply deleting VM 150 without a
verified stopped-state manifest. Use `make rebuild-media MEDIA_REBUILD_CONFIRM=true`
— see `docs/compose-vm.md`. The 24.04 template (VMID 900) has already been
deleted from `pve`, so that rebuild is forward-only.

GitHub `deploy-reusable.yml` does the same for deployment modes that include
infrastructure. It prepares SSH access to the Proxmox host, runs
`scripts/ci/ensure_target_image.sh`, and then applies Terraform. For VM targets
the workflow makes Packer available before the image ensure step. The helper
generates an ephemeral Packer SSH key when the controller does not already
provide one; Packer uses it only when a missing VM template must be built.
