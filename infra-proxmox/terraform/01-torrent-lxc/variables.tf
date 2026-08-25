variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "dns_domain" {
  type    = string
  default = "home.arpa"
}
variable "dns_servers" {
  type    = list(string)
  default = ["192.168.1.3"]
}

variable "admin_pubkey" {
  type    = string
  default = ""
}

variable "qbittorrent_lxc_vmid" {
  type    = number
  default = 171
}

variable "qbittorrent_lxc_name" {
  type    = string
  default = "01-torrent-lxc"
}

variable "qbittorrent_lxc_ip_address" {
  type    = string
  default = "192.168.1.71/24"
}

variable "qbittorrent_lxc_gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "qbittorrent_lxc_datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "qbittorrent_lxc_disk_gb" {
  type    = number
  default = 10
}

variable "qbittorrent_staging_mount_volume" {
  description = "Mount point backing volume for /srv/torrent-staging. Use a Proxmox storage id (volume mount) or a host path (bind mount; requires root@pam auth)."
  type        = string
  default     = "/srv/staging-ssd/"
}

variable "qbittorrent_staging_mount_size" {
  description = "Size for the staging mount (only used for volume mounts). Set to null when using a bind mount path."
  type        = string
  default     = null
}

variable "qbittorrent_staging_mount_path" {
  description = "Path inside the container for the staging mount."
  type        = string
  default     = "/srv/torrent-staging"
}

variable "qbittorrent_appdata_mount_volume" {
  description = "Mount point backing volume for qBittorrent config (bind mount from Proxmox host)."
  type        = string
  default     = "/srv/appdata/qbittorrent"
}

variable "qbittorrent_appdata_mount_path" {
  description = "Path inside the container for the qBittorrent config mount."
  type        = string
  default     = "/srv/appdata/qbittorrent"
}

variable "qbittorrent_downloads_mount_volume" {
  description = "Mount point backing volume for completed downloads (bind mount from Proxmox host)."
  type        = string
  default     = "/srv/media/downloads"
}

variable "qbittorrent_downloads_mount_path" {
  description = "Path inside the container for the completed downloads mount."
  type        = string
  default     = "/srv/media/downloads"
}

variable "qbittorrent_lxc_cores" {
  type    = number
  default = 4
}

variable "qbittorrent_lxc_rate_limit_mb_s" {
  description = "Network rate limit for the LXC NIC (MB/s). Useful to prevent qBittorrent from saturating LAN/WAN and starving SSH/Plex."
  type        = number
  default     = null
}

variable "qbittorrent_lxc_memory_mb" {
  type    = number
  default = 1280
}

variable "qbittorrent_lxc_swap_mb" {
  type    = number
  default = 512
}

variable "qbittorrent_lxc_unprivileged" {
  type = bool
  # This stack uses Proxmox mount points (host bind mounts).
  # Privileged LXCs are the simplest way to avoid UID/GID mapping surprises.
  default = false
}

variable "qbittorrent_lxc_password" {
  type      = string
  sensitive = true
  default   = ""
}

# tflint-ignore: terraform_unused_declarations
variable "qbittorrent_lxc_username" {
  type    = string
  default = "toomhorvath"
}

variable "qbittorrent_lxc_os_type" {
  type    = string
  default = "ubuntu"
}

variable "qbittorrent_template_datastore_id" {
  type    = string
  default = "local"
}

variable "qbittorrent_template_file_name" {
  type    = string
  default = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

variable "qbittorrent_lxc_nesting" {
  type    = bool
  default = true
}

variable "qbittorrent_lxc_keyctl" {
  description = "LXC feature flag: keyctl. Proxmox only allows changing feature flags (except nesting) as root@pam, so leave null when using a non-root API token."
  type        = bool
  default     = null
}

variable "qbittorrent_lxc_fuse" {
  description = "LXC feature flag: fuse. Proxmox only allows changing feature flags (except nesting) as root@pam, so leave null when using a non-root API token."
  type        = bool
  default     = null
}

variable "qbittorrent_lxc_mount" {
  description = "LXC feature flag: allowed mount types. Leave null unless you need to mount filesystems inside the container."
  type        = list(string)
  default     = null
}
