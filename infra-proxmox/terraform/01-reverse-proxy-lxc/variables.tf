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

variable "reverse_proxy_lxc_vmid" {
  type    = number
  default = 162
}

variable "reverse_proxy_lxc_name" {
  type    = string
  default = "01-reverse-proxy-lxc"
}

variable "reverse_proxy_lxc_ip_address" {
  type    = string
  default = "192.168.1.4/24"
}

variable "reverse_proxy_lxc_gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "reverse_proxy_lxc_datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "reverse_proxy_lxc_disk_gb" {
  type    = number
  default = 10
}

variable "reverse_proxy_lxc_cores" {
  type    = number
  default = 1
}

variable "reverse_proxy_lxc_memory_mb" {
  type    = number
  default = 1024
}

variable "reverse_proxy_lxc_swap_mb" {
  type    = number
  default = 512
}

variable "reverse_proxy_lxc_unprivileged" {
  type    = bool
  default = true
}

variable "reverse_proxy_lxc_nesting" {
  type    = bool
  default = true
}

variable "reverse_proxy_lxc_password" {
  type      = string
  sensitive = true
  default   = ""
}

# tflint-ignore: terraform_unused_declarations
variable "reverse_proxy_lxc_username" {
  type    = string
  default = "toomhorvath"
}

variable "reverse_proxy_lxc_os_type" {
  type    = string
  default = "ubuntu"
}

variable "reverse_proxy_template_datastore_id" {
  type    = string
  default = "local"
}

variable "reverse_proxy_template_file_name" {
  type    = string
  default = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}
