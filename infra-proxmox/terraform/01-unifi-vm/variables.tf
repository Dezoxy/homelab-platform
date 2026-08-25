# --- Identity -------------------------------------------------------------

variable "vmid" {
  description = "Proxmox VM ID. 150 = 01-media-vm, 151 = 01-myapps-vm."
  type        = number
  default     = 152
}

variable "name" {
  description = "VM hostname."
  type        = string
  default     = "01-unifi-vm"
}

variable "template_vmid" {
  description = "Cloud-init template to clone (same Debian template the other VMs use)."
  type        = number
  default     = 901
}

variable "machine" {
  description = "QEMU machine type."
  type        = string
  default     = "q35"
}

variable "bios" {
  description = "Firmware."
  type        = string
  default     = "ovmf"
}

# --- Sizing ---------------------------------------------------------------

variable "cores" {
  description = "vCPU count. Matches 01-unifi-lxc; the controller is not CPU-bound at three APs."
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = <<-EOT
    RAM. Sized from measurement, not from the LXC's tfvars example: after the
    site restore the controller sat at ~1.6 GB used -- java 563 MB (Network),
    unifi-core 204 MB, two mongod ~165 MB, beam.smp 73 MB (RabbitMQ), plus the
    alloy agent. 4 GB is ~2.5x that, leaving room for the Java heap and Mongo
    cache to grow as time-series stats accumulate.

    Not 3 GB: UniFi OS Server runs strictly more services than the retired
    01-unifi-lxc did (which managed on 2 GB), and a freshly restored database
    understates steady-state usage.
  EOT
  type        = number
  default     = 4096
}

variable "memory_ballooning_mb" {
  description = "Minimum RAM when the host reclaims memory."
  type        = number
  default     = 2048
}

variable "datastore_id" {
  description = "Datastore for the VM disk."
  type        = string
  default     = "local-lvm"
}

variable "disk_gb" {
  description = <<-EOT
    Root disk. UniFi OS Server documents a ~20 GB minimum for itself; 40 leaves
    room for its own container images and application updates, which land on
    the VM disk rather than the VirtIO-FS share.
  EOT
  type        = number
  default     = 40
}

variable "data_disks_gb" {
  description = "Extra VM disks. Empty: the host owns persistent storage (see VirtIO-FS below)."
  type        = list(number)
  default     = []
}

# --- Network --------------------------------------------------------------

variable "bridge" {
  description = "Proxmox bridge."
  type        = string
  default     = "vmbr0"
}

variable "ip_address" {
  description = <<-EOT
    Static IPv4 with prefix. Not 192.168.1.8 -- 01-unifi-lxc keeps that until
    the migration is verified, and the router forward for TCP 8080 is what gets
    repointed at cutover.
  EOT
  type        = string
  default     = "192.168.1.75/24"
}

variable "ip_gateway" {
  description = "Default gateway."
  type        = string
  default     = "192.168.1.1"
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

# --- Credentials ----------------------------------------------------------

variable "bootstrap_password" {
  description = "cloud-init bootstrap password. Set via TF_VAR_bootstrap_password."
  type        = string
  sensitive   = true
}

variable "admin_pubkey" {
  description = "Admin SSH public key. Defaults to keys/toomhorvath.pub in the module."
  type        = string
  default     = ""
}

# --- VirtIO-FS ------------------------------------------------------------

variable "enable_virtiofs_shares" {
  description = <<-EOT
    Expose the host's /srv/appdata to this VM. This is the whole backup story:
    controller backups written under the share land in the tree
    01-backup-lxc's restic job walks, exactly as the LXC bind mount does today.
    Turning this off means nothing on this VM reaches offsite backup.
  EOT
  type        = bool
  default     = true
}

variable "virtiofs_appdata_mapping_name" {
  description = <<-EOT
    Proxmox directory mapping name, shared with 01-media-vm and created by that
    stack. It resolves to /srv/appdata on the host; the path is not a variable
    here because this stack attaches the share by mapping name and nothing else
    consumes it.
  EOT
  type        = string
  default     = "homelab-appdata"
}

variable "virtiofs_cache" {
  description = "VirtIO-FS cache mode."
  type        = string
  default     = "auto"
}

variable "virtiofs_direct_io" {
  description = "Bypass the guest page cache."
  type        = bool
  default     = false
}

variable "virtiofs_expose_acl" {
  description = "Expose POSIX ACLs through the share."
  type        = bool
  default     = true
}

variable "virtiofs_expose_xattr" {
  description = "Expose extended attributes through the share."
  type        = bool
  default     = true
}

variable "mount_guard_hook_script_file_id" {
  description = <<-EOT
    The fleet's fail-closed pre-start guard (scripts/ops/pve-mount-guard.sh,
    installed once to local:snippets/mount-guard.sh), attached to this VM.
    VMID 152 is in its list, requiring /srv/appdata.

    Declared rather than null so the attachment is reproduced on a REPLACEMENT;
    null only survives an in-place apply. Set to null to detach deliberately.
  EOT
  type        = string
  default     = "local:snippets/mount-guard.sh"
}
