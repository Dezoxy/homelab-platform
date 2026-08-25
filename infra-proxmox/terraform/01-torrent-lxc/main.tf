module "lxc" {
  source = "../modules/proxmox-lxc"

  node_name    = var.proxmox_node
  vmid         = var.qbittorrent_lxc_vmid
  name         = var.qbittorrent_lxc_name
  tags         = ["role-qbittorrent", "managed-by-terraform"]
  unprivileged = var.qbittorrent_lxc_unprivileged

  template_datastore_id = var.qbittorrent_template_datastore_id
  template_file_name    = var.qbittorrent_template_file_name
  os_type               = var.qbittorrent_lxc_os_type

  cores        = var.qbittorrent_lxc_cores
  memory_mb    = var.qbittorrent_lxc_memory_mb
  swap_mb      = var.qbittorrent_lxc_swap_mb
  datastore_id = var.qbittorrent_lxc_datastore_id
  disk_gb      = var.qbittorrent_lxc_disk_gb

  bridge          = var.bridge
  ip_address      = var.qbittorrent_lxc_ip_address
  gateway         = var.qbittorrent_lxc_gateway
  rate_limit_mb_s = var.qbittorrent_lxc_rate_limit_mb_s

  dns_domain   = var.dns_domain
  dns_servers  = var.dns_servers
  admin_pubkey = var.admin_pubkey
  password     = var.qbittorrent_lxc_password

  nesting = var.qbittorrent_lxc_nesting
  keyctl  = var.qbittorrent_lxc_keyctl
  fuse    = var.qbittorrent_lxc_fuse
  mount   = var.qbittorrent_lxc_mount

  mount_points = [
    {
      volume = var.qbittorrent_staging_mount_volume
      size   = var.qbittorrent_staging_mount_size
      path   = var.qbittorrent_staging_mount_path
    },
    {
      volume = var.qbittorrent_appdata_mount_volume
      path   = var.qbittorrent_appdata_mount_path
    },
    {
      volume = var.qbittorrent_downloads_mount_volume
      path   = var.qbittorrent_downloads_mount_path
    },
  ]

  startup_order      = 50
  startup_up_delay   = 0
  startup_down_delay = 60
}

moved {
  from = proxmox_virtual_environment_container.qbittorrent
  to   = module.lxc.proxmox_virtual_environment_container.this
}
