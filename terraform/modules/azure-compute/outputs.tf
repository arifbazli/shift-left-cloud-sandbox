output "vm_id" {
  description = "ID of the app VM (mocked — see main.tf's SEC_INTENT note)."
  value       = azurerm_linux_virtual_machine.app.id
}

output "function_app_id" {
  description = "ID of the Function App ARM resource (code deployment is out of scope, see main.tf)."
  value       = azurerm_linux_function_app.main.id
}

output "function_app_name" {
  description = "Name of the Function App."
  value       = azurerm_linux_function_app.main.name
}

output "aks_cluster_id" {
  description = "ID of the AKS cluster."
  value       = azurerm_kubernetes_cluster.main.id
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster."
  value       = azurerm_kubernetes_cluster.main.name
}
