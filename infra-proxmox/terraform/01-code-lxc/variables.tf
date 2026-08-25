variable "bridge" {
  description = "Proxmox bridge."
  type        = string
  default     = "vmbr0"
}

variable "dns_domain" {
  description = "Search domain."
  type        = string
  default     = "home.arpa"
}

variable "dns_servers" {
  description = "Resolvers (01-dns-lxc)."
  type        = list(string)
  default     = ["192.168.1.3"]
}

variable "admin_pubkey" {
  description = "Admin SSH public key. Defaults to keys/toomhorvath.pub in the module."
  type        = string
  default     = ""
}

# --- Identity -------------------------------------------------------------

variable "code_lxc_vmid" {
  description = <<-EOT
    Proxmox container ID.

    176, not 175. 175 was 01-guacamole-lxc and was destroyed minutes before
    this guest was created; reusing an id that recently means stale ARP
    entries, stale known_hosts and git history that says something else. The
    id is free either way, so the ambiguity buys nothing.
  EOT
  type        = number
  default     = 176
}

variable "code_lxc_name" {
  description = "Container hostname."
  type        = string
  default     = "01-code-lxc"
}

variable "code_lxc_ip_address" {
  description = "Static IPv4 with prefix. .78 for the same reason as the vmid: .77 was Guacamole's."
  type        = string
  default     = "192.168.1.78/24"
}

variable "code_lxc_gateway" {
  description = "Default gateway."
  type        = string
  default     = "192.168.1.1"
}

# --- Sizing ---------------------------------------------------------------

variable "code_lxc_cores" {
  description = "vCPU count. Extension installs and language servers are bursty rather than sustained."
  type        = number
  default     = 4
}

variable "code_lxc_memory_mb" {
  description = <<-EOT
    Memory CEILING, not a reservation -- the container costs the host only what
    it touches. That distinction is why this guest is an LXC at all rather than
    2 GB permanently added to 01-myapps-vm.

    4096 is generous on purpose: code-server itself is ~1 GB, but TypeScript
    and Python language servers plus a few extensions climb quickly, and being
    generous with a ceiling is close to free.
  EOT
  type        = number
  default     = 4096
}

variable "code_lxc_swap_mb" {
  description = "Swap."
  type        = number
  default     = 512
}

variable "code_lxc_datastore_id" {
  description = "Datastore for the container disk."
  type        = string
  default     = "local-lvm"
}

variable "code_lxc_disk_gb" {
  description = <<-EOT
    Rootfs. Deliberately modest: everything worth keeping lives on the appdata
    bind mount, so this holds only the OS, node and the code-server package.
  EOT
  type        = number
  default     = 16
}

# --- Container settings ---------------------------------------------------

variable "code_lxc_unprivileged" {
  description = <<-EOT
    PRIVILEGED (false), matching 01-torrent-lxc and 01-observability-lxc.

    Required by the bind mount: an unprivileged container shifts uids, so files
    written under /srv/appdata end up owned by a high-numbered host uid, which
    the restic job on 01-backup-lxc then cannot read cleanly.
  EOT
  type        = bool
  default     = false
}

variable "code_lxc_nesting" {
  description = "node/npm and extension installers expect to be able to unshare."
  type        = bool
  default     = true
}

variable "code_lxc_password" {
  description = "Bootstrap root password. Set via TF_VAR_code_lxc_password."
  type        = string
  sensitive   = true
  default     = ""
}

variable "code_lxc_os_type" {
  description = "Container OS type."
  type        = string
  default     = "ubuntu"
}

variable "code_template_datastore_id" {
  description = "Datastore holding the LXC template."
  type        = string
  default     = "local"
}

variable "code_template_file_name" {
  description = "LXC template file. Pinned to ubuntu-2604-lxc-v1 in infra-images/catalog.json."
  type        = string
  default     = "ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
}

# --- Persistent state -----------------------------------------------------

variable "code_appdata_mount_volume" {
  description = <<-EOT
    Host path bind-mounted into the container.

    A fresh directory rather than the old /srv/appdata/agent: that tree was
    pruned when 01-agent-lxc was retired in #793, so there is nothing to
    inherit and a name matching this guest is clearer.
  EOT
  type        = string
  default     = "/srv/appdata/code"
}

variable "code_appdata_mount_path" {
  description = "Mount path inside the container. Same path as the host, matching every other LXC here."
  type        = string
  default     = "/srv/appdata/code"
}
