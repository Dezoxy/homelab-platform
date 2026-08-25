module "lxc" {
  source = "../modules/proxmox-lxc"

  node_name    = var.proxmox_node
  vmid         = var.dns_lxc_vmid
  name         = var.dns_lxc_name
  tags         = ["role-dns", "managed-by-terraform"]
  unprivileged = var.dns_lxc_unprivileged

  template_datastore_id = var.dns_template_datastore_id
  template_file_name    = var.dns_template_file_name
  os_type               = var.dns_lxc_os_type

  cores        = var.dns_lxc_cores
  memory_mb    = var.dns_lxc_memory_mb
  swap_mb      = var.dns_lxc_swap_mb
  datastore_id = var.dns_lxc_datastore_id
  disk_gb      = var.dns_lxc_disk_gb

  bridge       = var.bridge
  ip_address   = var.dns_lxc_ip_address
  gateway      = var.dns_lxc_gateway
  ipv6_address = var.dns_lxc_ipv6_address

  dns_domain   = var.dns_domain
  dns_servers  = var.dns_servers
  admin_pubkey = var.admin_pubkey
  password     = var.dns_lxc_password

  nesting = var.dns_lxc_nesting

  # Start early so the rest of the stack can resolve names.
  startup_order      = 10
  startup_up_delay   = 10
  startup_down_delay = 60
}

moved {
  from = proxmox_virtual_environment_container.dns
  to   = module.lxc.proxmox_virtual_environment_container.this
}
