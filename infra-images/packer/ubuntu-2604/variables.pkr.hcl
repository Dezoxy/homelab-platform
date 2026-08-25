variable "proxmox_url" {
  type        = string
  description = "Example: https://pve.example.local:8006/api2/json"
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name, e.g. pve"
}

variable "proxmox_token_id" {
  type        = string
  description = "Example: packer@pve!tokenname"
  sensitive   = true
}

variable "proxmox_token_secret" {
  type        = string
  description = "API token secret"
  sensitive   = true
}

variable "vm_id" {
  type        = number
  description = "Fixed VMID for the template (e.g. 901)"
}

variable "iso_storage_pool" {
  type        = string
  description = "Proxmox storage holding ISOs (usually 'local')"
  default     = "local"
}

variable "iso_url" {
  type        = string
  description = "HTTP(S) URL to the Ubuntu ISO"
}

variable "iso_checksum" {
  type        = string
  description = "Checksum for the ISO (e.g. sha256:<hash>)"
}

variable "vm_storage_pool" {
  type        = string
  description = "Proxmox storage for VM disks (NVMe-backed pool)"
}

variable "bridge" {
  type        = string
  description = "Linux bridge, e.g. vmbr0"
  default     = "vmbr0"
}

variable "template_name" {
  type    = string
  default = "tpl-ubuntu-2604-base"
}

variable "ssh_username" {
  type    = string
  default = "packer"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key injected during build"
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to SSH private key used by Packer"
}

variable "ssh_timeout" {
  type        = string
  description = "Max time to wait for SSH after install (e.g. 20m)"
  default     = "20m"
}

variable "insecure_skip_tls_verify" {
  type    = bool
  default = true
}
