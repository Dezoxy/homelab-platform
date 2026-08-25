variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "dns_domain" {
  type    = string
  default = "home.arpa"
}

variable "dns_servers" {
  type = list(string)
  # Keep public fallbacks so the router can still authenticate during DNS maintenance windows.
  default = [
    "192.168.1.3",
    "1.1.1.1",
    "8.8.8.8",
  ]
}

variable "admin_pubkey" {
  type    = string
  default = ""
}

variable "tailscale_lxc_vmid" {
  type    = number
  default = 165
}

variable "tailscale_lxc_name" {
  type    = string
  default = "01-tailscale-lxc"
}

variable "tailscale_lxc_ip_address" {
  type    = string
  default = "192.168.1.7/24"
}

variable "tailscale_lxc_gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "tailscale_lxc_datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "tailscale_lxc_disk_gb" {
  type    = number
  default = 8
}

variable "tailscale_state_mount_volume" {
  description = "Persistent Proxmox host path that holds the Tailscale node identity across LXC replacements."
  type        = string
  default     = "/srv/appdata/tailscale"
}

variable "tailscale_state_mount_path" {
  description = "Path inside the LXC for persisted Tailscale daemon state."
  type        = string
  default     = "/var/lib/tailscale"
}

variable "tailscale_lxc_cores" {
  type    = number
  default = 1
}

variable "tailscale_lxc_memory_mb" {
  type    = number
  default = 512
}

variable "tailscale_lxc_swap_mb" {
  type    = number
  default = 512
}

variable "tailscale_lxc_unprivileged" {
  type    = bool
  default = false
}

variable "tailscale_lxc_nesting" {
  type    = bool
  default = true
}

variable "tailscale_lxc_password" {
  type      = string
  sensitive = true
  default   = ""
}

# tflint-ignore: terraform_unused_declarations
variable "tailscale_lxc_username" {
  type    = string
  default = "toomhorvath"
}

variable "tailscale_lxc_os_type" {
  type    = string
  default = "ubuntu"
}

variable "tailscale_template_datastore_id" {
  type    = string
  default = "local"
}

variable "tailscale_template_file_name" {
  type    = string
  default = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}
