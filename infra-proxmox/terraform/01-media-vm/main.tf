locals {
  virtiofs_mappings = var.enable_virtiofs_shares ? {
    (var.virtiofs_appdata_mapping_name) = var.virtiofs_appdata_host_path
    (var.virtiofs_media_mapping_name)   = var.virtiofs_media_host_path
  } : {}

}

# ---------------------------------------------------------------------------
# Hardware mappings (media-VM-specific; stay in the calling stack so the
# module remains generic)
# ---------------------------------------------------------------------------

resource "proxmox_hardware_mapping_pci" "igpu" {
  name = var.igpu_mapping_name
  map = [
    {
      id           = var.igpu_pci_id
      node         = var.proxmox_node
      path         = var.igpu_pci_path
      iommu_group  = var.igpu_iommu_group
      subsystem_id = var.igpu_subsystem_id
    },
  ]
}

resource "proxmox_hardware_mapping_pci" "usb_controller" {
  count = var.enable_usb_controller_passthrough ? 1 : 0
  name  = var.usb_controller_mapping_name
  map = [
    {
      id           = var.usb_controller_pci_id
      node         = var.proxmox_node
      path         = var.usb_controller_pci_path
      iommu_group  = var.usb_controller_iommu_group
      subsystem_id = var.usb_controller_subsystem_id
    },
  ]
}

resource "proxmox_hardware_mapping_dir" "virtiofs" {
  for_each = local.virtiofs_mappings

  name    = each.key
  comment = "Managed by Terraform (homelab)"

  map = [
    {
      node = var.proxmox_node
      path = each.value
    },
  ]
}

# ---------------------------------------------------------------------------
# VM
# ---------------------------------------------------------------------------

module "vm" {
  source = "../modules/proxmox-vm"

  node_name     = var.proxmox_node
  vmid          = var.vmid
  name          = var.name
  tags          = ["tier-apps", "role-compose", "managed-by-terraform"]
  template_vmid = var.template_vmid
  machine       = var.machine
  bios          = var.bios

  cores                = var.cores
  memory_mb            = var.memory_mb
  memory_ballooning_mb = var.memory_ballooning_mb
  datastore_id         = var.datastore_id
  disk_gb              = var.disk_gb
  data_disks_gb        = var.data_disks_gb

  bridge     = var.bridge
  ip_address = var.ip_address
  ip_gateway = var.ip_gateway

  dns_domain  = var.dns_domain
  dns_servers = var.dns_servers

  bootstrap_password  = var.bootstrap_password
  admin_pubkey        = var.admin_pubkey
  hook_script_file_id = var.mount_guard_hook_script_file_id

  # Pass resolved mapping names so the module stays agnostic of the dir mapping resources.
  virtiofs_shares = [for m in proxmox_hardware_mapping_dir.virtiofs : {
    mapping      = m.name
    cache        = var.virtiofs_cache
    direct_io    = var.virtiofs_direct_io
    expose_acl   = var.virtiofs_expose_acl
    expose_xattr = var.virtiofs_expose_xattr
  }]

  hostpci = concat(
    [
      {
        device  = "hostpci0"
        mapping = proxmox_hardware_mapping_pci.igpu.name
        pcie    = var.machine == "q35" ? var.igpu_pcie : false
        xvga    = var.igpu_xvga
      },
    ],
    var.enable_usb_controller_passthrough ? [
      {
        device  = "hostpci1"
        mapping = proxmox_hardware_mapping_pci.usb_controller[0].name
        pcie    = false
        xvga    = false
      },
    ] : []
  )

  agent_enabled = true

  # Start after core infra containers (DNS, reverse-proxy, edge).
  startup_order      = 35
  startup_up_delay   = 20
  startup_down_delay = 120
}

# ---------------------------------------------------------------------------
# State migration: old resource name → module address
# ---------------------------------------------------------------------------

moved {
  from = proxmox_virtual_environment_vm.compose_01
  to   = proxmox_virtual_environment_vm.media_vm
}

moved {
  from = proxmox_virtual_environment_vm.media_vm
  to   = module.vm.proxmox_virtual_environment_vm.this
}
