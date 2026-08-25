# Shared bpg/proxmox provider variable declarations. Every stack symlinks
# this file as proxmox_variables.tf so we don't redeclare the same six vars
# in eleven places.
#
# All values are populated from the secret store (Azure Key Vault) at runtime via TF_VAR_* env vars
# (see scripts/dev/terraform_plan.sh + scripts/ci/export_runtime_env.sh).
# Defaults match the homelab Proxmox node so a stack plans cleanly without
# any tfvars file when the env is set.

variable "proxmox_url" {
  description = "Proxmox API endpoint URL (e.g. https://192.168.1.239:8006/api2/json)."
  type        = string
}

variable "proxmox_node" {
  description = "Proxmox node name to deploy on."
  type        = string
  default     = "pve"
}

variable "proxmox_token_id" {
  description = "Proxmox API token id. Preferred auth method; root@pam fallback runs only when this is empty."
  type        = string
  default     = ""
}

variable "proxmox_token_secret" {
  description = "Proxmox API token secret matching proxmox_token_id."
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_username" {
  description = "Proxmox username for the root@pam fallback auth method. Leave empty when using the API token."
  type        = string
  default     = ""
}

variable "proxmox_password" {
  description = "Proxmox password for the root@pam fallback auth method. Required only for stacks that need root API access (e.g. privileged-LXC bind mounts)."
  type        = string
  sensitive   = true
  default     = ""
}
