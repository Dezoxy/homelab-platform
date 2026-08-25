output "vmid" {
  description = "Proxmox container ID."
  value       = proxmox_virtual_environment_container.this.vm_id
}

output "ip_address" {
  description = "Container IPv4 address (with prefix length)."
  value       = var.ip_address
}

output "name" {
  description = "Container hostname."
  value       = var.name
}
