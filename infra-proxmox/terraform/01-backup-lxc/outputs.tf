output "vmid" {
  description = "Proxmox VM/container ID."
  value       = module.lxc.vmid
}

output "name" {
  description = "VM/container hostname."
  value       = module.lxc.name
}

output "ip_address" {
  description = "IPv4 address (with prefix length)."
  value       = module.lxc.ip_address
}
