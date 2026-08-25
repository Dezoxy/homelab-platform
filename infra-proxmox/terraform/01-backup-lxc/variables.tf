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

variable "backup_lxc_vmid" {
  type    = number
  default = 173
}

variable "backup_lxc_name" {
  type    = string
  default = "01-backup-lxc"
}

variable "backup_lxc_ip_address" {
  type    = string
  default = "192.168.1.73/24"
}

variable "backup_lxc_gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "backup_lxc_datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "backup_lxc_disk_gb" {
  type    = number
  default = 8
}

variable "backup_appdata_mount_volume" {
  description = "Mount point backing volume for the host appdata tree (bind mount from Proxmox host)."
  type        = string
  default     = "/srv/appdata"
}

variable "backup_appdata_mount_path" {
  description = "Path inside the container for the host appdata mount."
  type        = string
  default     = "/srv/appdata"
}

variable "backup_time_machine_mount_volume" {
  description = "Host path backing the Time Machine SMB share."
  type        = string
  default     = "/mnt/d16/backups/macbook-backup"
}

variable "backup_time_machine_mount_path" {
  description = "Path inside the container for the Time Machine SMB share."
  type        = string
  default     = "/srv/appdata/macbook-backup"
}

variable "backup_lxc_cores" {
  type    = number
  default = 2
}

variable "backup_lxc_memory_mb" {
  type    = number
  default = 2048
}

variable "backup_lxc_swap_mb" {
  type    = number
  default = 512
}

variable "backup_lxc_unprivileged" {
  type = bool
  # This stack uses a Proxmox host bind mount for /srv/appdata.
  # Privileged LXCs are the simplest way to avoid UID/GID mapping surprises.
  default = false
}

variable "backup_lxc_password" {
  type      = string
  sensitive = true
  default   = ""
}

# tflint-ignore: terraform_unused_declarations
variable "backup_lxc_username" {
  type    = string
  default = "toomhorvath"
}

variable "backup_lxc_os_type" {
  type    = string
  default = "ubuntu"
}

variable "backup_template_datastore_id" {
  type    = string
  default = "local"
}

variable "backup_template_file_name" {
  type    = string
  default = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

variable "backup_lxc_nesting" {
  type    = bool
  default = true
}
