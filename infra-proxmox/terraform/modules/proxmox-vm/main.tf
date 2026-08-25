locals {
  # Extra data disks start at scsi2 to avoid renumbering the existing root disk (scsi0).
  data_disk_offset = 2

  is_windows = var.guest_os == "windows"

  # Linux guests are reached over SSH and have never had a console; Windows
  # needs one as the fallback path when RDP is down. An explicit vga_type
  # still wins over both defaults.
  vga_type = coalesce(var.vga_type, local.is_windows ? "std" : "none")

  tpm_state_datastore_id = coalesce(var.tpm_state_datastore_id, var.datastore_id)
}

resource "proxmox_virtual_environment_vm" "this" {
  node_name           = var.node_name
  vm_id               = var.vmid
  name                = var.name
  tags                = var.tags
  machine             = var.machine
  bios                = var.bios
  on_boot             = var.start_on_boot
  started             = true
  hook_script_file_id = var.hook_script_file_id

  dynamic "efi_disk" {
    for_each = var.bios == "ovmf" ? [1] : []
    content {
      datastore_id      = var.datastore_id
      type              = "4m"
      pre_enrolled_keys = var.efi_pre_enrolled_keys
    }
  }

  clone {
    vm_id = var.template_vmid
    full  = true
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
    floating  = var.memory_ballooning_mb
  }

  scsi_hardware = var.scsi_hardware

  vga {
    type = local.vga_type
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.disk_gb
    discard      = "on"
    iothread     = var.disk_iothread
    ssd          = var.disk_ssd
  }

  dynamic "disk" {
    for_each = { for idx, size in var.data_disks_gb : idx => size }
    content {
      datastore_id = var.datastore_id
      interface    = format("scsi%d", tonumber(disk.key) + local.data_disk_offset)
      size         = disk.value
      discard      = "on"
      iothread     = var.disk_iothread
      ssd          = var.disk_ssd
    }
  }

  dynamic "virtiofs" {
    for_each = var.virtiofs_shares
    content {
      mapping      = virtiofs.value.mapping
      cache        = virtiofs.value.cache
      direct_io    = virtiofs.value.direct_io
      expose_acl   = virtiofs.value.expose_acl
      expose_xattr = virtiofs.value.expose_xattr
    }
  }

  dynamic "hostpci" {
    for_each = var.hostpci
    content {
      device  = hostpci.value.device
      mapping = hostpci.value.mapping
      pcie    = hostpci.value.pcie
      xvga    = hostpci.value.xvga
      rombar  = hostpci.value.rombar
    }
  }

  # Cloud-init, and therefore every value it carries, is Linux-only. Windows
  # has no datasource for it: the drive would attach, be ignored, and the guest
  # would come up on DHCP while this state still claimed the static address.
  # A Windows guest gets its identity from the unattend.xml baked into its
  # template instead -- see infra-images/packer/windows-11/.
  dynamic "initialization" {
    for_each = local.is_windows ? [] : [1]
    content {
      ip_config {
        ipv4 {
          address = var.ip_address
          gateway = var.ip_gateway
        }
      }

      dns {
        domain  = var.dns_domain
        servers = var.dns_servers
      }

      user_account {
        username = "toomhorvath"
        password = var.bootstrap_password
        keys = compact([
          var.admin_pubkey != "" ? var.admin_pubkey : try(trimspace(file("${path.root}/../../../keys/toomhorvath.pub")), ""),
        ])
      }
    }
  }

  # null leaves ostype unmanaged. Every existing guest sits at Proxmox's
  # `other`; declaring a value unconditionally would rewrite all of them.
  dynamic "operating_system" {
    for_each = var.operating_system_type == null ? [] : [1]
    content {
      type = var.operating_system_type
    }
  }

  # swtpm state volume. Required by Windows 11, unused by every Linux guest.
  dynamic "tpm_state" {
    for_each = var.tpm_version == null ? [] : [1]
    content {
      datastore_id = local.tpm_state_datastore_id
      version      = var.tpm_version
    }
  }

  dynamic "agent" {
    for_each = var.agent_enabled ? [1] : []
    content {
      enabled = true
    }
  }

  startup {
    order    = var.startup_order
    up_delay = var.startup_up_delay
    # null leaves the attribute unset, which is what every caller got before
    # this input existed -- so adding it changes nothing for them.
    down_delay = var.startup_down_delay
  }
}
