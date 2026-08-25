# 01-unifi-vm -- UniFi OS Server host.
#
# A VM, not an LXC, deliberately. UniFi OS Server requires Podman >= 4.3 and
# Ubiquiti does not support Docker; running Podman inside an unprivileged LXC
# needs community workarounds for sysctl, su/group restrictions, the /proc
# mount and /dev/net/tun. A VM removes that entire class of problem, and this
# repo already has the pattern (01-media-vm, 01-myapps-vm).
#
# Storage follows 01-media-vm: the Proxmox host owns /srv/appdata and exposes
# it over VirtIO-FS. That is what puts controller backups inside the tree
# 01-backup-lxc's restic job already walks -- no backup role change, same as
# the bind mount 01-unifi-lxc uses today.

# The homelab-appdata directory mapping is NOT created here. It already exists
# and is owned by 01-media-vm's Terraform state; declaring it again would mean
# two states claiming one Proxmox object -- a duplicate-name apply failure at
# best, and cross-stack drift at worst. A named mapping can be attached to more
# than one VM, so this stack just consumes it.
#
# Consequence worth knowing: destroying 01-media-vm removes the mapping and
# breaks this VM's share. If the two ever need to be independent, give this
# stack its own mapping name pointing at the same host path.
locals {
  virtiofs_shares = var.enable_virtiofs_shares ? [
    {
      mapping      = var.virtiofs_appdata_mapping_name
      cache        = var.virtiofs_cache
      direct_io    = var.virtiofs_direct_io
      expose_acl   = var.virtiofs_expose_acl
      expose_xattr = var.virtiofs_expose_xattr
    },
  ] : []
}

# The fail-closed guard lives at scripts/ops/pve-mount-guard.sh, deployed once
# to local:snippets/mount-guard.sh and attached to every guest that needs a host
# mount -- VMID 152 is in its list requiring /srv/appdata (see #748). This stack
# attaches that SHARED snippet; it does not declare a stack-local one, which
# would overwrite the central attachment with a hook covering only this guest
# and silently narrow the protection.
#
# Previously left unset. null means UNMANAGED rather than "must be empty", so
# the hand-made attachment does survive an in-place apply -- but it does NOT
# survive a REPLACEMENT, which clones from the template and carries no
# hookscript. Naming the shared snippet costs nothing in place (the value
# already matches live) and makes a rebuilt guest come up guarded.

module "vm" {
  source = "../modules/proxmox-vm"

  node_name     = var.proxmox_node
  vmid          = var.vmid
  name          = var.name
  tags          = ["tier-apps", "role-unifi", "managed-by-terraform"]
  template_vmid = var.template_vmid
  machine       = var.machine
  bios          = var.bios

  cores                = var.cores
  memory_mb            = var.memory_mb
  memory_ballooning_mb = var.memory_ballooning_mb
  datastore_id         = var.datastore_id
  disk_gb              = var.disk_gb
  data_disks_gb        = var.data_disks_gb

  bridge     = var.bridge
  ip_address = var.ip_address
  ip_gateway = var.ip_gateway

  dns_domain  = var.dns_domain
  dns_servers = var.dns_servers

  bootstrap_password = var.bootstrap_password
  admin_pubkey       = var.admin_pubkey

  virtiofs_shares = local.virtiofs_shares

  hook_script_file_id = var.mount_guard_hook_script_file_id

  agent_enabled = true

  # Same slot as 01-media-vm: after DNS, reverse-proxy and edge are up.
  startup_order    = 40
  startup_up_delay = 20
}
