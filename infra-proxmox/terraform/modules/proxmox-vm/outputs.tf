output "vmid" {
  description = "VM ID."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "ip_address" {
  description = "VM IPv4 address (with prefix length)."
  value       = var.ip_address
}

output "name" {
  description = "VM name."
  value       = var.name
}
