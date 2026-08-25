# VM clone from the Ubuntu 26.04 base template. No GPU/USB passthrough and no
# pre-start mount guard, but it DOES take one VirtIO-FS share.
#
# That share is why this comment changed. The host started out stateless --
# netcheck keeps nothing -- but notification-digest arrived with a SQLite
# state database (dedup ledger, digest history, arc context) living on the
# VM's local disk, and restic runs on 01-backup-lxc against the shared
# /srv/appdata volume, which this VM had no path to. So a lost VM disk took
# state.db and all seven of its local snapshots with it. Sharing appdata is
# how every other stateful guest here reaches offsite backup (see the media
# and unifi VMs), and this is that same route.
#
# Only appdata is shared, not media: nothing on this host reads or writes the
# media tree, and an unnecessary share is an unnecessary blast radius.

locals {
  # Reference the EXISTING cluster-level directory mapping rather than
  # declaring a proxmox_hardware_mapping_dir here. 01-media-vm's stack
  # already creates "homelab-appdata"; a second resource with the same name
  # would fight it across two terraform states for one Proxmox object.
  # Mappings are cluster-scoped and freely shared between guests.
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

module "vm" {
  source = "../modules/proxmox-vm"

  node_name     = var.proxmox_node
  vmid          = var.vmid
  name          = var.name
  tags          = ["tier-apps", "role-compose", "managed-by-terraform"]
  template_vmid = var.template_vmid
  machine       = var.machine
  bios          = var.bios

  cores                = var.cores
  memory_mb            = var.memory_mb
  memory_ballooning_mb = var.memory_ballooning_mb
  datastore_id         = var.datastore_id
  disk_gb              = var.disk_gb

  bridge     = var.bridge
  ip_address = var.ip_address
  ip_gateway = var.ip_gateway

  dns_domain  = var.dns_domain
  dns_servers = var.dns_servers

  bootstrap_password = var.bootstrap_password
  admin_pubkey       = var.admin_pubkey

  agent_enabled = true

  virtiofs_shares = local.virtiofs_shares

  # Start after the media VM (40); before nothing critical.
  startup_order    = 42
  startup_up_delay = 20
  # Adopted from the live VM, where it was set by hand and had drifted from
  # this file since 2026-05-29 -- the module had no input for it, so every
  # terraform apply wanted to strip it back to unset. Encoded here instead of
  # reverted: this host runs notification-digest's SQLite state, and the
  # shutdown grace is what lets it close cleanly during a host shutdown
  # rather than being cut off mid-write.
  startup_down_delay = 120
}
