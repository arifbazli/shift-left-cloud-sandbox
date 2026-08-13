output "resource_group_name" {
  description = "Name of the shared resource group every azure-* module attaches to."
  value       = azurerm_resource_group.main.name
}

output "location" {
  description = "Azure region (fixed: eastus) shared by every azure-* module."
  value       = azurerm_resource_group.main.location
}

output "vnet_id" {
  description = "ID of the main VNet."
  value       = azurerm_virtual_network.main.id
}

output "private_subnet_id" {
  description = "ID of the private subnet."
  value       = azurerm_subnet.private.id
}

output "app_nsg_id" {
  description = "ID of the app-tier network security group."
  value       = azurerm_network_security_group.app.id
}
