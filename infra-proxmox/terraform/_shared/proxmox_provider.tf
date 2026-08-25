# Shared bpg/proxmox provider declaration for every stack under
# infra-proxmox/terraform/. Each stack references this file via a symlink
# (proxmox_provider.tf -> ../_shared/proxmox_provider.tf) so the provider
# version + auth-method-fallback logic lives in exactly one place.
#
# Auth-method precedence:
#   - If proxmox_username and proxmox_password are both set, use root@pam
#     username/password auth. Required for stacks that need root API
#     access (e.g. 01-torrent-lxc with privileged-LXC bind mounts —
#     see scripts/ci/terraform_apply.sh's root@pam fallback handling).
#   - Otherwise, use the API token. Preferred for everything else.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox_url
  api_token = (var.proxmox_username != "" && var.proxmox_password != "") ? null : (
    var.proxmox_token_id != "" && var.proxmox_token_secret != "" ? "${var.proxmox_token_id}=${var.proxmox_token_secret}" : null
  )
  username = (var.proxmox_username != "" && var.proxmox_password != "") ? var.proxmox_username : null
  password = (var.proxmox_username != "" && var.proxmox_password != "") ? var.proxmox_password : null
  insecure = true
}
