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

variable "cloudflared_lxc_vmid" {
  type    = number
  default = 160
}

variable "cloudflared_lxc_name" {
  type    = string
  default = "01-edge-lxc"
}

variable "cloudflared_lxc_ip_address" {
  type    = string
  default = "192.168.1.2/24"
}

variable "cloudflared_lxc_gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "cloudflared_lxc_datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "cloudflared_lxc_disk_gb" {
  type    = number
  default = 4
}

variable "cloudflared_lxc_cores" {
  type    = number
  default = 1
}

variable "cloudflared_lxc_memory_mb" {
  type    = number
  default = 768
}

variable "cloudflared_lxc_swap_mb" {
  type    = number
  default = 512
}

variable "cloudflared_lxc_unprivileged" {
  type    = bool
  default = true
}

variable "cloudflared_lxc_nesting" {
  type    = bool
  default = true
}

variable "cloudflared_lxc_password" {
  type      = string
  sensitive = true
  default   = ""
}

# tflint-ignore: terraform_unused_declarations
variable "cloudflared_lxc_username" {
  type    = string
  default = "toomhorvath"
}

variable "cloudflared_lxc_os_type" {
  type    = string
  default = "ubuntu"
}

variable "cloudflared_template_datastore_id" {
  type    = string
  default = "local"
}

variable "cloudflared_template_file_name" {
  type    = string
  default = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

variable "cloudflared_tunnel_token" {
  type      = string
  sensitive = true
  default   = ""
}
