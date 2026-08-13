output "storage_account_name" {
  description = "Name of the storage account (S3-equivalent host for the artifacts container)."
  value       = azurerm_storage_account.main.name
}

output "artifacts_container_name" {
  description = "Name of the artifacts blob container."
  value       = azurerm_storage_container.artifacts.name
}

output "table_name" {
  description = "Name of the Table Storage table (DynamoDB equivalent)."
  value       = azurerm_storage_table.main.name
}
