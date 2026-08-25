module "lxc" {
  source = "../modules/proxmox-lxc"

  node_name    = var.proxmox_node
  vmid         = var.tailscale_lxc_vmid
  name         = var.tailscale_lxc_name
  tags         = ["role-tailscale", "managed-by-terraform"]
  unprivileged = var.tailscale_lxc_unprivileged

  template_datastore_id = var.tailscale_template_datastore_id
  template_file_name    = var.tailscale_template_file_name
  os_type               = var.tailscale_lxc_os_type

  cores        = var.tailscale_lxc_cores
  memory_mb    = var.tailscale_lxc_memory_mb
  swap_mb      = var.tailscale_lxc_swap_mb
  datastore_id = var.tailscale_lxc_datastore_id
  disk_gb      = var.tailscale_lxc_disk_gb

  bridge     = var.bridge
  ip_address = var.tailscale_lxc_ip_address
  gateway    = var.tailscale_lxc_gateway

  dns_domain   = var.dns_domain
  dns_servers  = var.dns_servers
  admin_pubkey = var.admin_pubkey
  password     = var.tailscale_lxc_password

  nesting = var.tailscale_lxc_nesting

  # Required for kernel-mode Tailscale routing; this was previously set manually on PVE.
  device_passthrough = [
    {
      path       = "/dev/net/tun"
      deny_write = false
      uid        = 0
      gid        = 0
      mode       = "0666"
    },
  ]

  # Retain node identity and route approval across root-disk replacement.
  mount_points = [
    {
      volume = var.tailscale_state_mount_volume
      path   = var.tailscale_state_mount_path
    },
  ]

  # Start early enough to be available for CI jobs that rely on subnet routing.
  startup_order      = 15
  startup_up_delay   = 5
  startup_down_delay = 30
}

moved {
  from = proxmox_virtual_environment_container.tailscale
  to   = module.lxc.proxmox_virtual_environment_container.this
}
