# 01-myapps-vm — general-purpose Docker host for self-hosted apps. Sized for
# netcheck plus heavier local apps such as the Kali-backed T3MP3ST stack. No
# VirtIO-FS shares, no PCI passthrough, no extra data disks. Resource/identity
# defaults live here; template_vmid is overridden at deploy time from
# infra-images/catalog.json via the image-pin resolver.

variable "name" {
  type    = string
  default = "01-myapps-vm"
}

variable "vmid" {
  type    = number
  default = 151
}

variable "template_vmid" {
  type    = number
  default = 901
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "cores" {
  type    = number
  default = 4
}

# Halved from 8192 by hand on the host and mirrored here. NOTE the margin is
# thin: the 30-day peak working set measured 3.57 GB, so 4096 leaves ~500 MB.
# The bulk of that is the Chromium container plus playwright-mcp (~1 GB
# together); a heavier browser session is what would push this over. If the
# guest starts OOM-killing, this is the first number to raise.
variable "memory_mb" {
  type    = number
  default = 4096
}

# 0 = ballooning disabled, which is what the live guest has: `qm config` shows
# no balloon: line at all, and the provider represents that as floating = 0.
# Setting this equal to memory_mb (the module's documented "disable" value)
# would actually ENABLE the balloon device with a 4 GB floor -- verified via
# plan, which showed `~ floating = 0 -> 4096`.
variable "memory_ballooning_mb" {
  description = <<-EOT
    Floor the host may reclaim down to. 0 means NO ballooning at all, which is
    what this was, and it is why the host had no option but to swap.

    Added 2026-08-25 after a since-retired Windows guest pushed the host into
    swap. With four VMs reserving 24576 MB of a 31819 MB host and no balloon
    device on this one, none of its slack was reachable, so the kernel paged
    out 4.4 GB of GUEST memory instead. Measured then: 4096 held, ~2815 used.

    The Windows guest is gone, but the floor stays -- the lesson is not about
    that guest. A VM without a balloon RESERVES its memory, so its unused
    portion is invisible to every other guest on the node.

    2048 is a floor, not a cap: the guest keeps its full 4096 until the host is
    genuinely short, then virtio-balloon reclaims page cache first.
  EOT
  type        = number
  default     = 2048
}

variable "disk_gb" {
  type    = number
  default = 120
}

variable "machine" {
  type    = string
  default = "q35"
}

variable "bios" {
  type    = string
  default = "ovmf"
}

variable "ip_address" {
  type    = string
  default = "192.168.1.72/24"
}

variable "ip_gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "dns_domain" {
  type    = string
  default = "home.arpa"
}

variable "dns_servers" {
  type    = list(string)
  default = ["192.168.1.3"]
}

variable "bootstrap_password" {
  type      = string
  sensitive = true
}

variable "admin_pubkey" {
  type    = string
  default = ""
}

# ---------------------------------------------------------------------------
# VirtIO-FS (appdata share, for offsite backup reachability)
# ---------------------------------------------------------------------------

variable "enable_virtiofs_shares" {
  description = <<-EOT
    Expose the host's /srv/appdata to this VM over VirtIO-FS. This is the
    whole offsite-backup story for anything stateful here: restic runs on
    01-backup-lxc against that shared volume, so a path this VM can write to
    is what gets notification-digest's state snapshots off the VM's own disk.
    Turning this off means nothing on this VM reaches offsite backup.
  EOT
  type        = bool
  default     = true
}

variable "virtiofs_appdata_mapping_name" {
  description = <<-EOT
    Name of the EXISTING Proxmox directory mapping for /srv/appdata. Created
    by 01-media-vm's stack; referenced here rather than re-declared, since
    mappings are cluster-scoped and two terraform states must not both own
    one Proxmox object.
  EOT
  type        = string
  default     = "homelab-appdata"
}

variable "virtiofs_cache" {
  description = "VirtIO-FS cache mode. 'never' matches the media VM."
  type        = string
  default     = "never"
}

variable "virtiofs_direct_io" {
  description = "Enable VirtIO-FS direct IO."
  type        = bool
  default     = false
}

variable "virtiofs_expose_acl" {
  description = "Expose POSIX ACLs over VirtIO-FS."
  type        = bool
  default     = true
}

variable "virtiofs_expose_xattr" {
  description = "Expose extended attributes over VirtIO-FS."
  type        = bool
  default     = true
}
