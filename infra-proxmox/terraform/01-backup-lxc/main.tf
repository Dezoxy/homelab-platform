# No pre-start mount guard is declared here. The fail-closed guard lives at
# scripts/ops/pve-mount-guard.sh, deployed once to local:snippets/mount-guard.sh
# and attached centrally to every guest that needs a host mount -- VMID 173 is in
# its list, requiring /srv/appdata and /mnt/d16.
#
# A stack-local hookscript used to be declared here behind
# backup_enable_pre_start_mount_guard. It was dead: the variable defaulted to
# false, its snippet had a different filename so it never even shadowed the real
# guard, and it carried an OLDER 35-line copy of the script that checked a single
# path -- missing the per-branch mergerfs checks that are the whole point, since
# mergerfs mounts happily with only some branches present. Removed rather than
# left as a switch someone could flip expecting protection.
#
# The module now keeps hook_script_file_id in ignore_changes, because the
# container resource -- unlike the VM one -- plans to CLEAR a null attribute
# rather than leave it unmanaged. See modules/proxmox-lxc/main.tf.

module "lxc" {
  source = "../modules/proxmox-lxc"

  node_name    = var.proxmox_node
  vmid         = var.backup_lxc_vmid
  name         = var.backup_lxc_name
  tags         = ["role-backup", "managed-by-terraform"]
  unprivileged = var.backup_lxc_unprivileged

  template_datastore_id = var.backup_template_datastore_id
  template_file_name    = var.backup_template_file_name
  os_type               = var.backup_lxc_os_type

  cores        = var.backup_lxc_cores
  memory_mb    = var.backup_lxc_memory_mb
  swap_mb      = var.backup_lxc_swap_mb
  datastore_id = var.backup_lxc_datastore_id
  disk_gb      = var.backup_lxc_disk_gb

  bridge     = var.bridge
  ip_address = var.backup_lxc_ip_address
  gateway    = var.backup_lxc_gateway

  dns_domain   = var.dns_domain
  dns_servers  = var.dns_servers
  admin_pubkey = var.admin_pubkey
  password     = var.backup_lxc_password

  nesting = var.backup_lxc_nesting

  # Read appdata directly from the Proxmox host, with Time Machine on a larger media branch.
  mount_points = [
    {
      volume = var.backup_appdata_mount_volume
      path   = var.backup_appdata_mount_path
    },
    {
      volume = var.backup_time_machine_mount_volume
      path   = var.backup_time_machine_mount_path
    },
  ]

  # Late: avoid boot-time contention with apps and storage-heavy workloads.
  startup_order = 65
  # Manual start, per docs/proxmox-boot-shutdown-order.md: a restic job firing
  # while the node is still coming up is exactly what this avoids. The order
  # above is still meaningful -- it governs the shutdown sequence.
  start_on_boot      = false
  startup_up_delay   = 0
  startup_down_delay = 60
}

moved {
  from = proxmox_virtual_environment_container.backup
  to   = module.lxc.proxmox_virtual_environment_container.this
}
