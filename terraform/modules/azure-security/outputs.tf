output "key_vault_id" {
  description = "ID of the Key Vault."
  value       = azurerm_key_vault.main.id
}

output "key_vault_uri" {
  description = "URI of the Key Vault."
  value       = azurerm_key_vault.main.vault_uri
}

output "app_config_secret_id" {
  description = "Versioned ID of the app-config secret."
  value       = azurerm_key_vault_secret.app_config.id
}
