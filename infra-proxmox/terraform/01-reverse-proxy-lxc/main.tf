module "lxc" {
  source = "../modules/proxmox-lxc"

  node_name    = var.proxmox_node
  vmid         = var.reverse_proxy_lxc_vmid
  name         = var.reverse_proxy_lxc_name
  tags         = ["role-reverse-proxy", "managed-by-terraform"]
  unprivileged = var.reverse_proxy_lxc_unprivileged

  template_datastore_id = var.reverse_proxy_template_datastore_id
  template_file_name    = var.reverse_proxy_template_file_name
  os_type               = var.reverse_proxy_lxc_os_type

  cores        = var.reverse_proxy_lxc_cores
  memory_mb    = var.reverse_proxy_lxc_memory_mb
  swap_mb      = var.reverse_proxy_lxc_swap_mb
  datastore_id = var.reverse_proxy_lxc_datastore_id
  disk_gb      = var.reverse_proxy_lxc_disk_gb

  bridge     = var.bridge
  ip_address = var.reverse_proxy_lxc_ip_address
  gateway    = var.reverse_proxy_lxc_gateway

  dns_domain   = var.dns_domain
  dns_servers  = var.dns_servers
  admin_pubkey = var.admin_pubkey
  password     = var.reverse_proxy_lxc_password

  nesting = var.reverse_proxy_lxc_nesting

  # Start after DNS; provides LAN ingress for apps.
  startup_order      = 20
  startup_up_delay   = 10
  startup_down_delay = 30
}

moved {
  from = proxmox_virtual_environment_container.reverse_proxy
  to   = module.lxc.proxmox_virtual_environment_container.this
}
