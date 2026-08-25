data "proxmox_file" "template" {
  content_type = "vztmpl"
  datastore_id = var.template_datastore_id
  node_name    = var.node_name
  file_name    = var.template_file_name
}

resource "proxmox_virtual_environment_container" "this" {
  node_name           = var.node_name
  vm_id               = var.vmid
  tags                = var.tags
  unprivileged        = var.unprivileged
  started             = true
  start_on_boot       = var.start_on_boot
  hook_script_file_id = var.hook_script_file_id

  environment_variables = length(var.environment_variables) > 0 ? var.environment_variables : null

  operating_system {
    template_file_id = data.proxmox_file.template.id
    type             = var.os_type
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory_mb
    swap      = var.swap_mb
  }

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_gb
  }

  dynamic "mount_point" {
    for_each = var.mount_points
    content {
      volume = mount_point.value.volume
      path   = mount_point.value.path
      size   = mount_point.value.size
    }
  }

  dynamic "device_passthrough" {
    for_each = var.device_passthrough
    content {
      path       = device_passthrough.value.path
      deny_write = device_passthrough.value.deny_write
      gid        = device_passthrough.value.gid
      mode       = device_passthrough.value.mode
      uid        = device_passthrough.value.uid
    }
  }

  network_interface {
    name       = "eth0"
    bridge     = var.bridge
    rate_limit = var.rate_limit_mb_s
  }

  features {
    nesting = var.nesting
    keyctl  = var.keyctl
    fuse    = var.fuse
    mount   = var.mount
  }

  initialization {
    hostname = var.name

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }

      dynamic "ipv6" {
        for_each = var.ipv6_address != null ? [var.ipv6_address] : []
        content {
          address = ipv6.value
        }
      }
    }

    dns {
      domain  = var.dns_domain
      servers = var.dns_servers
    }

    user_account {
      password = var.password != "" ? var.password : null
      keys = compact([
        var.admin_pubkey != "" ? var.admin_pubkey : try(trimspace(file("${path.root}/../../../keys/toomhorvath.pub")), ""),
      ])
    }
  }

  startup {
    order    = var.startup_order
    up_delay = var.startup_up_delay
    # null leaves the attribute unset, which is what every caller got before
    # this input existed -- so adding it changes nothing for them.
    down_delay = var.startup_down_delay
  }

  # The Proxmox API stores `password` as a write-only attribute — the provider
  # can't read it back, so terraform state never knows what's set. Without this
  # ignore_changes block, every plan after a bootstrap would show a phantom
  # `+ password = (sensitive value)` diff that ForceNew flags for replacement.
  # The bootstrap password is still applied on initial create.
  lifecycle {
    ignore_changes = [
      initialization[0].user_account[0].password,
      # The fail-closed mount guard (scripts/ops/pve-mount-guard.sh) is deployed
      # once to local:snippets/mount-guard.sh and attached centrally to every
      # guest that needs a host mount. Terraform must not fight that.
      #
      # 01-unifi-vm documents the intended strategy -- leave the attribute unset
      # and let the provider treat null as UNMANAGED -- and verified it with a
      # plan against a live guest. That verification was done against a VM, and
      # it does NOT generalise: proxmox_virtual_environment_vm leaves a null
      # hook_script_file_id alone, while proxmox_virtual_environment_container
      # plans to clear it. Measured 2026-08-24, five containers at once:
      #
      #   - hook_script_file_id = "local:snippets/mount-guard.sh" -> null
      #
      # That is the guard being removed from agent, tailscale, torrent, backup
      # and observability -- the half of the fstab-nofail pair that stops a
      # container starting against a missing mergerfs branch, which is how Plex
      # ends up rescanning an empty library and dropping titles from it.
      hook_script_file_id,
    ]
  }
}
