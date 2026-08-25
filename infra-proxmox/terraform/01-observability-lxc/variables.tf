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

variable "observability_lxc_vmid" {
  type    = number
  default = 174
}

variable "observability_lxc_name" {
  type    = string
  default = "01-observability-lxc"
}

variable "observability_lxc_ip_address" {
  type    = string
  default = "192.168.1.74/24"
}

variable "observability_lxc_gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "observability_lxc_datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "observability_lxc_disk_gb" {
  type    = number
  default = 16
}

variable "observability_appdata_mount_volume" {
  description = "Mount point backing volume for observability appdata (bind mount from Proxmox host)."
  type        = string
  default     = "/srv/appdata/observability"
}

variable "observability_appdata_mount_path" {
  description = "Path inside the container for the observability appdata mount."
  type        = string
  default     = "/srv/appdata/observability"
}

variable "observability_lxc_cores" {
  type    = number
  default = 4
}

variable "observability_lxc_memory_mb" {
  type    = number
  default = 3072
}

variable "observability_lxc_swap_mb" {
  type    = number
  default = 512
}

variable "observability_lxc_unprivileged" {
  type = bool
  # This stack uses Proxmox mount points (host bind mounts).
  # Privileged LXCs are the simplest way to avoid UID/GID mapping surprises.
  default = false
}

variable "observability_lxc_password" {
  type      = string
  sensitive = true
  default   = ""
}

# tflint-ignore: terraform_unused_declarations
variable "observability_lxc_username" {
  type    = string
  default = "toomhorvath"
}

variable "observability_lxc_os_type" {
  type    = string
  default = "ubuntu"
}

variable "observability_template_datastore_id" {
  type    = string
  default = "local"
}

variable "observability_template_file_name" {
  type    = string
  default = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

variable "observability_lxc_nesting" {
  type    = bool
  default = true
}

variable "observability_lxc_keyctl" {
  description = "LXC feature flag: keyctl. Proxmox only allows changing feature flags (except nesting) as root@pam, so leave null when using a non-root API token."
  type        = bool
  default     = null
}

variable "observability_lxc_fuse" {
  description = "LXC feature flag: fuse. Proxmox only allows changing feature flags (except nesting) as root@pam, so leave null when using a non-root API token."
  type        = bool
  default     = null
}

variable "observability_lxc_mount" {
  description = "LXC feature flag: allowed mount types. Leave null unless you need to mount filesystems inside the container."
  type        = list(string)
  default     = null
}
