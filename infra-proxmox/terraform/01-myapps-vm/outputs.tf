output "vmid" {
  description = "Proxmox VM ID."
  value       = module.vm.vmid
}

output "name" {
  description = "VM hostname."
  value       = module.vm.name
}

output "ip_address" {
  description = "IPv4 address (with prefix length)."
  value       = module.vm.ip_address
}
