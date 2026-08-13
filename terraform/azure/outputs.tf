# =============================================================================
# terraform/azure/outputs.tf — one block per module
# =============================================================================
# Mirrors terraform/outputs.tf's pattern. Will be consumed by a future
# verify-azure.sh the same way terraform/outputs.tf is consumed by
# scripts/verify.sh — not built yet, out of scope for this step.
# =============================================================================

# ── azure-network ────────────────────────────────────────────────────────────
output "resource_group_name" {
  description = "Name of the shared resource group every azure-* module attaches to."
  value       = module.azure-network.resource_group_name
}

output "location" {
  description = "Azure region (fixed: eastus) shared by every azure-* module."
  value       = module.azure-network.location
}

output "vnet_id" {
  description = "ID of the main VNet."
  value       = module.azure-network.vnet_id
}

output "private_subnet_id" {
  description = "ID of the private subnet."
  value       = module.azure-network.private_subnet_id
}

output "app_nsg_id" {
  description = "ID of the app-tier network security group."
  value       = module.azure-network.app_nsg_id
}

# ── azure-storage ────────────────────────────────────────────────────────────
output "storage_account_name" {
  description = "Name of the storage account (S3-equivalent host for the artifacts container)."
  value       = module.azure-storage.storage_account_name
}

output "artifacts_container_name" {
  description = "Name of the artifacts blob container."
  value       = module.azure-storage.artifacts_container_name
}

output "table_name" {
  description = "Name of the Table Storage table (DynamoDB equivalent)."
  value       = module.azure-storage.table_name
}

# ── azure-security ───────────────────────────────────────────────────────────
output "key_vault_id" {
  description = "ID of the Key Vault."
  value       = module.azure-security.key_vault_id
}

output "key_vault_uri" {
  description = "URI of the Key Vault."
  value       = module.azure-security.key_vault_uri
}

output "app_config_secret_id" {
  description = "Versioned ID of the app-config secret."
  value       = module.azure-security.app_config_secret_id
}

# ── azure-compute ────────────────────────────────────────────────────────────
output "vm_id" {
  description = "ID of the app VM (mocked)."
  value       = module.azure-compute.vm_id
}

output "function_app_id" {
  description = "ID of the Function App ARM resource."
  value       = module.azure-compute.function_app_id
}

output "function_app_name" {
  description = "Name of the Function App."
  value       = module.azure-compute.function_app_name
}

output "aks_cluster_id" {
  description = "ID of the AKS cluster."
  value       = module.azure-compute.aks_cluster_id
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster."
  value       = module.azure-compute.aks_cluster_name
}
