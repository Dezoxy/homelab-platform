# 01-code-lxc -- code-server (VS Code in the browser) plus the agent CLIs.
#
# Replaces the editor half of the retired 01-agent-lxc, and replaces the
# Windows VM as the way to get a real editor from any device.
#
# An LXC rather than a slot on 01-myapps-vm, for the reason this node keeps
# teaching: LXC memory is a CEILING, VM memory is a RESERVATION. Putting
# code-server on myapps would have meant raising that VM 4096 -> 6144, i.e.
# 2 GB reserved whether the editor is open or not. Here it costs the host
# roughly what it actually uses and near nothing idle -- which matters on a
# host that was in swap earlier today.
#
# It also keeps a runaway extension away from the digest, garmin, jobs-refresh
# and withings job units on myapps.
#
# PRIVILEGED, like 01-torrent-lxc and 01-observability-lxc and for the same
# reason: the bind mount below. An unprivileged container shifts uids, so files
# written under /srv/appdata land owned by a high-numbered host uid and the
# restic job cannot read them cleanly. 01-guacamole-lxc could stay unprivileged
# precisely because it had no bind mount.

module "lxc" {
  source = "../modules/proxmox-lxc"

  node_name    = var.proxmox_node
  vmid         = var.code_lxc_vmid
  name         = var.code_lxc_name
  tags         = ["tier-apps", "role-code-server", "managed-by-terraform"]
  unprivileged = var.code_lxc_unprivileged

  template_datastore_id = var.code_template_datastore_id
  template_file_name    = var.code_template_file_name
  os_type               = var.code_lxc_os_type

  cores        = var.code_lxc_cores
  memory_mb    = var.code_lxc_memory_mb
  swap_mb      = var.code_lxc_swap_mb
  datastore_id = var.code_lxc_datastore_id
  disk_gb      = var.code_lxc_disk_gb

  bridge     = var.bridge
  ip_address = var.code_lxc_ip_address
  gateway    = var.code_lxc_gateway

  dns_domain   = var.dns_domain
  dns_servers  = var.dns_servers
  admin_pubkey = var.admin_pubkey
  password     = var.code_lxc_password

  # node/npm and extension installers expect to be able to unshare.
  nesting = var.code_lxc_nesting

  # The whole point of the guest. Editor settings, installed extensions, open
  # workspaces AND the codex/claude CLI auth state all live here, so they
  # survive a container rebuild and land in 01-backup-lxc's restic run for
  # free. Nothing valuable is on the container rootfs.
  mount_points = [
    {
      volume = var.code_appdata_mount_volume
      path   = var.code_appdata_mount_path
    },
  ]

  # After the app stacks, before the manual-start backup container.
  startup_order      = 55
  startup_up_delay   = 0
  startup_down_delay = 30
}
