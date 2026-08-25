# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

variable "node_name" {
  description = "Proxmox node to create the container on."
  type        = string
}

variable "vmid" {
  description = "Container ID."
  type        = number
}

variable "name" {
  description = "Hostname for the container."
  type        = string
}

variable "tags" {
  description = "List of Proxmox tags to apply."
  type        = list(string)
}

variable "unprivileged" {
  description = "Run the container in unprivileged mode."
  type        = bool
  default     = true
}

variable "hook_script_file_id" {
  description = "Proxmox file resource ID for a pre-start hook script. Leave null to skip."
  type        = string
  default     = null
}

variable "environment_variables" {
  description = "Environment variables to inject into the container at boot (e.g. TUNNEL_TOKEN for Cloudflare)."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# OS template
# ---------------------------------------------------------------------------

variable "template_datastore_id" {
  description = "Proxmox datastore that holds the OS template."
  type        = string
}

variable "template_file_name" {
  description = "Filename of the LXC OS template archive."
  type        = string
}

variable "os_type" {
  description = "LXC OS type hint for Proxmox (e.g. ubuntu, debian)."
  type        = string
  default     = "ubuntu"
}

# ---------------------------------------------------------------------------
# Resources
# ---------------------------------------------------------------------------

variable "cores" {
  description = "Number of CPU cores."
  type        = number
}

variable "memory_mb" {
  description = "Dedicated memory in MiB."
  type        = number
}

variable "swap_mb" {
  description = "Swap in MiB."
  type        = number
  default     = 0
}

variable "datastore_id" {
  description = "Proxmox datastore for the container root disk."
  type        = string
  default     = "local-lvm"
}

variable "disk_gb" {
  description = "Root disk size in GiB."
  type        = number
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "bridge" {
  description = "Network bridge name."
  type        = string
  default     = "vmbr0"
}

variable "ip_address" {
  description = "IPv4 address with prefix length (e.g. 192.168.1.3/24)."
  type        = string
}

variable "gateway" {
  description = "Default IPv4 gateway."
  type        = string
}

variable "ipv6_address" {
  description = "IPv6 address or 'auto'. Omit (leave null) to skip IPv6 configuration."
  type        = string
  default     = null
}

variable "rate_limit_mb_s" {
  description = "Network interface rate limit in MB/s. Null disables rate limiting."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Cloud-init / initialisation
# ---------------------------------------------------------------------------

variable "dns_domain" {
  description = "Search domain for the container."
  type        = string
  default     = "home.arpa"
}

variable "dns_servers" {
  description = "DNS server addresses."
  type        = list(string)
  default     = ["192.168.1.3"]
}

variable "admin_pubkey" {
  description = "SSH public key to inject. Falls back to keys/toomhorvath.pub relative to the repo root."
  type        = string
  default     = ""
}

variable "password" {
  description = "Root password. Leave empty to disable password authentication."
  type        = string
  sensitive   = true
  default     = ""
}

# ---------------------------------------------------------------------------
# LXC features
# ---------------------------------------------------------------------------

variable "nesting" {
  description = "Enable LXC nesting (required for Docker-in-LXC)."
  type        = bool
  default     = true
}

variable "keyctl" {
  description = "Enable keyctl feature. Leave null to use Proxmox default (only root@pam can change this)."
  type        = bool
  default     = null
}

variable "fuse" {
  description = "Enable FUSE feature. Leave null to use Proxmox default."
  type        = bool
  default     = null
}

variable "mount" {
  description = "Allowed filesystem types to mount inside the container. Leave null for Proxmox default."
  type        = list(string)
  default     = null
}

# ---------------------------------------------------------------------------
# Mount points
# ---------------------------------------------------------------------------

variable "mount_points" {
  description = "Additional mount points (bind mounts or storage volumes) to attach to the container."
  type = list(object({
    volume = string
    path   = string
    size   = optional(string)
  }))
  default = []
}

variable "device_passthrough" {
  description = "Host devices to make available inside the container, such as /dev/net/tun."
  type = list(object({
    path       = string
    deny_write = optional(bool)
    gid        = optional(number)
    mode       = optional(string)
    uid        = optional(number)
  }))
  default = []
}

# ---------------------------------------------------------------------------
# Startup ordering
# ---------------------------------------------------------------------------

variable "startup_order" {
  description = "Boot order position (lower numbers start earlier)."
  type        = number
}

variable "startup_up_delay" {
  description = "Seconds to wait after this container starts before booting the next one."
  type        = number
  default     = 10
}

variable "start_on_boot" {
  description = <<-EOT
    Whether Proxmox autostarts this container with the node.

    Was hardcoded true, which disagreed with the fleet: docs/proxmox-boot-
    shutdown-order.md documents 01-backup-lxc as deliberately manual-start
    ("avoids a job firing mid-boot"), and the live host matched the doc rather
    than the module. Any apply would have quietly re-enabled it, so the
    decision needs to live here rather than only on the hypervisor.

    startup_order is still set for a manual-start guest: order governs the
    SHUTDOWN sequence too, which is what the container needs on a host reboot.
  EOT
  type        = bool
  default     = true
}

variable "startup_down_delay" {
  description = <<-EOT
    Seconds Proxmox waits for this container to shut down cleanly before
    moving on to the next one during a host shutdown. null leaves it unset
    (the prior behaviour for every caller).

    Mirrors the same input on the proxmox-vm module. It was missing here,
    which meant the fleet's hand-tuned shutdown delays lived only on the
    hypervisor: a terraform apply reset every one of them to unset.
  EOT
  type        = number
  default     = null
}
