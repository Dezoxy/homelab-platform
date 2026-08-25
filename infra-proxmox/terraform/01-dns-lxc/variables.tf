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
  default = ["9.9.9.9", "8.8.8.8"]
}

variable "admin_pubkey" {
  type    = string
  default = ""
}

variable "dns_lxc_vmid" {
  type    = number
  default = 161
}

variable "dns_lxc_name" {
  type    = string
  default = "01-dns-lxc"
}

variable "dns_lxc_ip_address" {
  type    = string
  default = "192.168.1.3/24"
}

variable "dns_lxc_gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "dns_lxc_ipv6_address" {
  type    = string
  default = "auto"
}

variable "dns_lxc_datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "dns_lxc_disk_gb" {
  type    = number
  default = 6
}

variable "dns_lxc_cores" {
  type    = number
  default = 1
}

variable "dns_lxc_memory_mb" {
  type    = number
  default = 768
}

variable "dns_lxc_swap_mb" {
  type    = number
  default = 512
}

variable "dns_lxc_unprivileged" {
  type    = bool
  default = true
}

variable "dns_lxc_nesting" {
  type    = bool
  default = true
}

variable "dns_lxc_password" {
  type      = string
  sensitive = true
  default   = ""
}

# tflint-ignore: terraform_unused_declarations
variable "dns_lxc_username" {
  type    = string
  default = "toomhorvath"
}

variable "dns_lxc_os_type" {
  type    = string
  default = "ubuntu"
}

variable "dns_template_datastore_id" {
  type    = string
  default = "local"
}

variable "dns_template_file_name" {
  type    = string
  default = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}
