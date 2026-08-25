output "vmid" {
  description = "Proxmox VM/container ID."
  value       = module.vm.vmid
}

output "name" {
  description = "VM/container hostname."
  value       = module.vm.name
}

output "ip_address" {
  description = "IPv4 address (with prefix length)."
  value       = module.vm.ip_address
}
