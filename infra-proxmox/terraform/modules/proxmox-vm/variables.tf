# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

variable "node_name" {
  description = "Proxmox node to create the VM on."
  type        = string
}

variable "vmid" {
  description = "VM ID."
  type        = number
}

variable "name" {
  description = "VM name."
  type        = string
}

variable "tags" {
  description = "List of Proxmox tags to apply."
  type        = list(string)
}

variable "machine" {
  description = "Machine type (q35 or i440fx)."
  type        = string
  default     = "q35"
}

variable "bios" {
  description = "BIOS type (seabios or ovmf). Use ovmf for UEFI."
  type        = string
  default     = "ovmf"
}

variable "hook_script_file_id" {
  description = "Proxmox file resource ID for a pre-start hook script. Leave null to skip."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Clone source
# ---------------------------------------------------------------------------

variable "template_vmid" {
  description = "VMID of the Packer-built cloud-init template to clone from."
  type        = number
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

variable "memory_ballooning_mb" {
  description = "Minimum memory when ballooning is active (MiB). Set equal to memory_mb to disable ballooning."
  type        = number
}

variable "datastore_id" {
  description = "Proxmox datastore for all disks."
  type        = string
  default     = "local-lvm"
}

variable "disk_gb" {
  description = "Root disk size in GiB (scsi0)."
  type        = number
}

variable "scsi_hardware" {
  description = <<-EOT
    SCSI controller model. Default matches every existing guest exactly
    (verified live 2026-08-25: 150, 151 and 152 are all virtio-scsi-pci), so
    adding this input replans nothing.

    virtio-scsi-single gives each disk its own controller, which is what makes
    per-disk iothread possible. Worth it for a guest whose PAGEFILE lives on
    that disk: when the guest is short on memory, disk latency IS the lag.
  EOT
  type        = string
  default     = "virtio-scsi-pci"
}

variable "disk_iothread" {
  description = <<-EOT
    Give the disk its own I/O thread instead of sharing the main QEMU thread.
    Requires scsi_hardware = "virtio-scsi-single".

    Default false matches all three Linux guests; they are servers whose I/O is
    steady rather than latency-sensitive.
  EOT
  type        = bool
  default     = false
}

variable "disk_ssd" {
  description = <<-EOT
    Advertise the disk to the guest as an SSD.

    Matters far more for Windows than for Linux: told it is rotational, Windows
    schedules defragmentation, applies spinning-disk prefetch heuristics, and
    does not treat the volume as trim-capable -- all on NVMe-backed storage.
    Linux ignores the hint almost entirely, which is why the default stays
    false and no existing guest moves.
  EOT
  type        = bool
  default     = false
}

variable "data_disks_gb" {
  description = "Sizes in GiB for additional data disks (scsi2, scsi3, …). Empty list = no extra disks."
  type        = list(number)
  default     = []
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
  description = "IPv4 address with prefix length (e.g. 192.168.1.70/24)."
  type        = string
}

variable "ip_gateway" {
  description = "Default IPv4 gateway."
  type        = string
}

# ---------------------------------------------------------------------------
# Cloud-init / initialisation
# ---------------------------------------------------------------------------

variable "dns_domain" {
  description = "Search domain."
  type        = string
  default     = "home.arpa"
}

variable "dns_servers" {
  description = "DNS server addresses."
  type        = list(string)
  default     = ["192.168.1.3"]
}

variable "bootstrap_password" {
  description = "Initial user account password."
  type        = string
  sensitive   = true
}

variable "admin_pubkey" {
  description = "SSH public key to inject. Falls back to keys/toomhorvath.pub relative to the repo root."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# VirtIO-FS shares
# ---------------------------------------------------------------------------

variable "virtiofs_shares" {
  description = "VirtIO-FS shares to attach. Each entry maps a Proxmox Directory Mapping name to mount options."
  type = list(object({
    mapping      = string
    cache        = optional(string, "never")
    direct_io    = optional(bool, false)
    expose_acl   = optional(bool, true)
    expose_xattr = optional(bool, true)
  }))
  default = []
}

# ---------------------------------------------------------------------------
# PCI passthrough
# ---------------------------------------------------------------------------

variable "hostpci" {
  description = "PCI passthrough devices to attach. device must be hostpci0, hostpci1, etc."
  type = list(object({
    device  = string
    mapping = string
    pcie    = optional(bool, false)
    xvga    = optional(bool, false)
    rombar  = optional(bool, true)
  }))
  default = []
}

# ---------------------------------------------------------------------------
# Guest agent
# ---------------------------------------------------------------------------

variable "agent_enabled" {
  description = "Enable the QEMU guest agent."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Startup ordering
# ---------------------------------------------------------------------------

variable "start_on_boot" {
  description = <<-EOT
    Whether Proxmox autostarts this VM with the node. Mirrors the input of the
    same name on modules/proxmox-lxc, which exists because a hardcoded true
    silently disagreed with a documented manual-start guest.

    Worth turning off for a guest whose memory the node cannot spare while it
    is idle: an 8 GB Windows desktop on a 31 GB host is 8 GB the other guests
    do not get back until someone notices.

    startup_order is still set for a manual-start guest: order governs the
    SHUTDOWN sequence too, which is what it needs on a host reboot.
  EOT
  type        = bool
  default     = true
}

variable "startup_order" {
  description = "Boot order position (lower numbers start earlier)."
  type        = number
}

variable "startup_down_delay" {
  description = <<-EOT
    Seconds Proxmox waits for this guest to shut down cleanly before moving
    on to the next one during a host shutdown. null leaves it unset (the
    prior behaviour for every caller).

    Worth setting for a guest running a database: the wait is what lets the
    app close its files instead of being cut off mid-write.
  EOT
  type        = number
  default     = null
}

variable "startup_up_delay" {
  description = "Seconds to wait after this VM starts before booting the next one."
  type        = number
  default     = 10
}

# ---------------------------------------------------------------------------
# Guest OS
# ---------------------------------------------------------------------------

variable "guest_os" {
  description = <<-EOT
    Guest operating-system family. Drives the settings that differ structurally
    between a Linux and a Windows guest rather than exposing each as its own
    flag, so an invalid combination (Windows + cloud-init) cannot be expressed:

      linux    cloud-init drives IP/DNS/user; headless console
      windows  no cloud-init at all; a real console

    Windows has no cloud-init datasource, so the initialization block is
    omitted entirely for it. That is not a cosmetic difference: leaving the
    block in place makes the provider attach a cloud-init drive the guest
    silently ignores, and the VM then falls back to DHCP while Terraform still
    reports the static address it thinks it configured.
  EOT
  type        = string
  default     = "linux"

  validation {
    condition     = contains(["linux", "windows"], var.guest_os)
    error_message = "guest_os must be either \"linux\" or \"windows\"."
  }
}

variable "operating_system_type" {
  description = <<-EOT
    Proxmox ostype (win11, win10, l26, ...). null leaves the attribute
    unmanaged, which is what every existing caller gets -- all three live VMs
    and template 901 sit at the provider's `other`, and setting a value here
    would rewrite that on the next apply.

    Worth setting for Windows: ostype selects the QEMU timer and ACPI defaults
    Windows expects, and Proxmox uses it to pick sane device models.
  EOT
  type        = string
  default     = null
}

variable "vga_type" {
  description = <<-EOT
    Display adapter. null resolves per guest_os: "none" for Linux (matching
    every existing VM, which is reached over SSH) and "std" for Windows.

    Windows needs a real adapter even when the plan is to reach it over RDP:
    the console is the only way in when RDP is broken, and Proxmox's noVNC
    console shows nothing at all with type=none.
  EOT
  type        = string
  default     = null
}

variable "efi_pre_enrolled_keys" {
  description = <<-EOT
    Enroll Microsoft's Secure Boot keys into the EFI vars disk.

    Default false matches live state exactly -- 150, 151, 152 and template 901
    all carry `pre-enrolled-keys=0`, so adding this attribute does not replan
    any existing stack.

    Windows 11 requires Secure Boot, which needs the Microsoft keys present to
    validate its bootloader. Only meaningful when bios = "ovmf".
  EOT
  type        = bool
  default     = false
}

variable "tpm_version" {
  description = <<-EOT
    Software TPM version ("v1.2" or "v2.0"). null attaches no TPM, which is the
    existing behaviour for every caller.

    Windows 11 refuses to install or upgrade without TPM 2.0. Proxmox satisfies
    this with swtpm, which needs its own small state volume -- hence
    tpm_state_datastore_id below.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.tpm_version == null || contains(["v1.2", "v2.0"], coalesce(var.tpm_version, "v2.0"))
    error_message = "tpm_version must be null, \"v1.2\" or \"v2.0\"."
  }
}

variable "tpm_state_datastore_id" {
  description = "Datastore for the swtpm state volume. Defaults to datastore_id when null."
  type        = string
  default     = null
}
