variable "environment" {
  description = "Tag value. Never set to 'prod' for this sandbox."
  type        = string
  default     = "sandbox"

  # "flociartifacts" (14 chars) + this value must stay <= 24 chars — Azure's
  # hard storage-account-name limit. 24 - 14 = 10. A validation block gives
  # a clear Terraform-time error instead of a confusing Azure API rejection
  # at apply time.
  validation {
    condition     = length(var.environment) <= 10
    error_message = "environment must be <= 10 characters — azurerm_storage_account.main's name is \"flociartifacts${var.environment}\", and Azure storage account names have a hard 24-character limit (\"flociartifacts\" alone is already 14)."
  }
}

variable "resource_group_name" {
  description = "Resource group to attach this module's resources to (from module.azure-network)."
  type        = string
}

variable "location" {
  description = "Azure region to attach this module's resources to (from module.azure-network)."
  type        = string
}
