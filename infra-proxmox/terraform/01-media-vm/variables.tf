variable "name" {
  type    = string
  default = "01-media-vm"
}
variable "vmid" {
  type    = number
  default = 150
}

# Pinned forward to the Ubuntu 26.04 template (vmid 901). media-vm still runs
# off the old 24.04 clone, so terraform-plan shows a destroy/recreate until it
# is rebuilt onto 2604 (guarded by `make rebuild-media`).
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
  default = 12
}
variable "memory_mb" {
  type    = number
  default = 8192
}
# 0 = ballooning disabled, matching the live guest (no balloon: line in
# `qm config`; the provider represents that as floating = 0).
variable "memory_ballooning_mb" {
  description = <<-EOT
    Floor the host may reclaim down to. 0 meant NO ballooning, and this guest
    is the fleet's largest single reservation: 8192 MB held, ~7379 MB in use,
    none of it reclaimable.

    APPLIED LIVE ONLY, on 2026-08-25 (`qm set 150 --balloon 4096`). This stack
    cannot currently be applied -- it still runs on the retired 24.04 template
    (vm_id 900 -> 901 forces replacement), so `terraform apply` here would
    DESTROY AND RECREATE the media VM. The value is recorded so the rebuild
    inherits it; until then live is authoritative and this is known drift.
    See the target_policy note in infra-images/catalog.json.
  EOT
  type        = number
  default     = 4096
}

variable "disk_gb" {
  type    = number
  default = 128
}

variable "data_disks_gb" {
  type    = list(number)
  default = []
}

variable "enable_virtiofs_shares" {
  description = "Expose host directories to the VM via VirtIO-FS (Proxmox Directory Mappings)."
  type        = bool
  default     = true
}

variable "virtiofs_appdata_mapping_name" {
  description = "Proxmox directory mapping id (mount tag inside the VM) for appdata."
  type        = string
  default     = "homelab-appdata"
}

variable "virtiofs_appdata_host_path" {
  description = "Host path on the Proxmox node to export as appdata (e.g. /srv/appdata)."
  type        = string
  default     = "/srv/appdata"
}

variable "virtiofs_media_mapping_name" {
  description = "Proxmox directory mapping id (mount tag inside the VM) for media."
  type        = string
  default     = "homelab-media"
}

variable "virtiofs_media_host_path" {
  description = "Host path on the Proxmox node to export as media (e.g. /srv/media)."
  type        = string
  default     = "/srv/media"
}

variable "virtiofs_cache" {
  description = "VirtIO-FS cache mode (e.g. auto, always, never)."
  type        = string
  default     = "never"
}

variable "virtiofs_direct_io" {
  description = "Whether to allow direct I/O for VirtIO-FS shares."
  type        = bool
  default     = false
}

variable "virtiofs_expose_acl" {
  description = "Expose POSIX ACLs in VirtIO-FS shares (implies xattr support)."
  type        = bool
  default     = true
}

variable "virtiofs_expose_xattr" {
  description = "Expose extended attributes in VirtIO-FS shares."
  type        = bool
  default     = true
}

variable "machine" {
  type    = string
  default = "q35"
}
variable "bios" {
  type    = string
  default = "ovmf"
}

variable "igpu_mapping_name" {
  type    = string
  default = "igpu-01-media-vm"
}
variable "igpu_pci_id" {
  type    = string
  default = "8086:a780"
}
variable "igpu_pci_path" {
  type    = string
  default = "0000:00:02.0"
}
variable "igpu_iommu_group" {
  type    = number
  default = 0
}
variable "igpu_subsystem_id" {
  type    = string
  default = "1849:a780"
}
variable "igpu_pcie" {
  type    = bool
  default = true
}
variable "igpu_xvga" {
  type    = bool
  default = true
}

variable "enable_usb_controller_passthrough" {
  type    = bool
  default = false
}

variable "usb_controller_mapping_name" {
  type    = string
  default = "usb-controller-01-media-vm"
}
variable "usb_controller_pci_id" {
  type    = string
  default = "8086:7a60"
}
variable "usb_controller_pci_path" {
  type    = string
  default = "0000:00:14.0"
}
variable "usb_controller_iommu_group" {
  type    = number
  default = 3
}
variable "usb_controller_subsystem_id" {
  type    = string
  default = "1849:7a60"
}

variable "ip_address" {
  type    = string
  default = "192.168.1.70/24"
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

variable "mount_guard_hook_script_file_id" {
  description = <<-EOT
    The fleet's fail-closed pre-start guard, attached to this VM.

    Points at the SHARED snippet (scripts/ops/pve-mount-guard.sh, installed once
    to local:snippets/mount-guard.sh) rather than declaring a stack-local hook.
    A second, stack-local hookscript would overwrite that attachment with one
    covering only this guest, silently narrowing the protection -- which is the
    trap 01-unifi-vm's comment warns about, and why the previous stack-local
    implementation here was removed rather than enabled.

    Declared rather than left null because null means UNMANAGED: the hand-made
    attachment survives an in-place apply, but a REPLACEMENT clones from the
    template, which carries no hookscript. VMID 150 requires /srv/appdata and
    /srv/media; without the guard a rebuilt VM can boot against a missing
    mergerfs branch, and Plex then scans an empty library and removes titles
    from it.

    Set to null only to detach the guard deliberately.
  EOT
  type        = string
  default     = "local:snippets/mount-guard.sh"
}
