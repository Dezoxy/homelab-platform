packer {
  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = ">= 1.2.0"
    }
  }
}

source "proxmox-iso" "ubuntu2604" {
  proxmox_url              = var.proxmox_url
  insecure_skip_tls_verify = var.insecure_skip_tls_verify
  node                     = var.proxmox_node
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret

  vm_id                = var.vm_id
  vm_name              = var.template_name
  template_description = "Ubuntu 26.04 base template: cloud-init + qemu-guest-agent"

  # ISO
  iso_storage_pool = var.iso_storage_pool
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  unmount_iso      = true

  # Hardware
  qemu_agent      = true
  cores           = 2
  memory          = 2048
  cpu_type        = "host"
  bios            = "ovmf"
  machine         = "q35"
  scsi_controller = "virtio-scsi-pci"

  network_adapters {
    bridge = var.bridge
    model  = "virtio"
  }

  disks {
    type         = "scsi"
    disk_size    = "32G"
    storage_pool = var.vm_storage_pool
    format       = "raw"
  }

  efi_config {
    efi_storage_pool = var.vm_storage_pool
    efi_type         = "4m"
  }

  # Packer HTTP server serves NoCloud seed (user-data/meta-data)
  http_content = {
    "/user-data" = templatefile("${path.root}/http/user-data.tftpl", {
      template_name  = var.template_name
      ssh_username   = var.ssh_username
      ssh_public_key = var.ssh_public_key
    })
    "/meta-data" = templatefile("${path.root}/http/meta-data.tftpl", {
      template_name = var.template_name
    })
  }

  # SSH into installer environment after install completes
  ssh_username         = var.ssh_username
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = var.ssh_timeout

  # Autoinstall boot automation (UEFI/GRUB)
  boot_wait         = "5s"
  boot_key_interval = "150ms"

  # This sequence:
  # - hits ESC to stop the default boot
  # - enters the GRUB command line
  # - boots the kernel with explicit autoinstall args
  boot_command = [
    "<wait><esc><wait>c<wait>",
    "linux /casper/vmlinuz quiet autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ cloud-config-url=/dev/null ---",
    "<enter><wait>",
    "initrd /casper/initrd",
    "<enter><wait>",
    "boot<enter>"
  ]
}

build {
  sources = ["source.proxmox-iso.ubuntu2604"]

  provisioner "shell" {
    execute_command = "sudo -n -E bash '{{ .Path }}'"
    scripts = [
      "${path.root}/../../scripts/install_base.sh"
    ]
  }

  provisioner "shell" {
    execute_command = "sudo -n -E bash '{{ .Path }}'"
    inline = [
      "echo 'Image build complete'",
      "systemctl is-enabled qemu-guest-agent || true",
      "cloud-init status --wait || true"
    ]
  }

  provisioner "shell" {
    execute_command = "sudo -n -E bash '{{ .Path }}'"
    environment_vars = [
      "PACKER_SSH_USERNAME=${var.ssh_username}"
    ]
    scripts = [
      "${path.root}/../../scripts/cleanup.sh"
    ]
  }
}
