module "lxc" {
  source = "../modules/proxmox-lxc"

  node_name    = var.proxmox_node
  vmid         = var.cloudflared_lxc_vmid
  name         = var.cloudflared_lxc_name
  tags         = ["role-cloudflared", "managed-by-terraform"]
  unprivileged = var.cloudflared_lxc_unprivileged

  template_datastore_id = var.cloudflared_template_datastore_id
  template_file_name    = var.cloudflared_template_file_name
  os_type               = var.cloudflared_lxc_os_type

  cores        = var.cloudflared_lxc_cores
  memory_mb    = var.cloudflared_lxc_memory_mb
  swap_mb      = var.cloudflared_lxc_swap_mb
  datastore_id = var.cloudflared_lxc_datastore_id
  disk_gb      = var.cloudflared_lxc_disk_gb

  bridge     = var.bridge
  ip_address = var.cloudflared_lxc_ip_address
  gateway    = var.cloudflared_lxc_gateway

  dns_domain   = var.dns_domain
  dns_servers  = var.dns_servers
  admin_pubkey = var.admin_pubkey
  password     = var.cloudflared_lxc_password

  nesting = var.cloudflared_lxc_nesting

  environment_variables = var.cloudflared_tunnel_token != "" ? {
    TUNNEL_TOKEN = var.cloudflared_tunnel_token
  } : {}

  # Start after DNS + reverse proxy.
  startup_order      = 25
  startup_up_delay   = 5
  startup_down_delay = 30
}

moved {
  from = proxmox_virtual_environment_container.cloudflared
  to   = module.lxc.proxmox_virtual_environment_container.this
}
