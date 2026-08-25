module "lxc" {
  source = "../modules/proxmox-lxc"

  node_name    = var.proxmox_node
  vmid         = var.observability_lxc_vmid
  name         = var.observability_lxc_name
  tags         = ["role-observability", "managed-by-terraform"]
  unprivileged = var.observability_lxc_unprivileged

  template_datastore_id = var.observability_template_datastore_id
  template_file_name    = var.observability_template_file_name
  os_type               = var.observability_lxc_os_type

  cores        = var.observability_lxc_cores
  memory_mb    = var.observability_lxc_memory_mb
  swap_mb      = var.observability_lxc_swap_mb
  datastore_id = var.observability_lxc_datastore_id
  disk_gb      = var.observability_lxc_disk_gb

  bridge     = var.bridge
  ip_address = var.observability_lxc_ip_address
  gateway    = var.observability_lxc_gateway

  dns_domain   = var.dns_domain
  dns_servers  = var.dns_servers
  admin_pubkey = var.admin_pubkey
  password     = var.observability_lxc_password

  nesting = var.observability_lxc_nesting
  keyctl  = var.observability_lxc_keyctl
  fuse    = var.observability_lxc_fuse
  mount   = var.observability_lxc_mount

  # Bind mount from the Proxmox host so this container can persist observability config/data.
  mount_points = [
    {
      volume = var.observability_appdata_mount_volume
      path   = var.observability_appdata_mount_path
    },
  ]

  # Start after core infra and app stacks.
  startup_order      = 28
  startup_up_delay   = 5
  startup_down_delay = 30
}

moved {
  from = proxmox_virtual_environment_container.observability
  to   = module.lxc.proxmox_virtual_environment_container.this
}
