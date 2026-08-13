variable "environment" {
  description = "Tag value. Never set to 'prod' for this sandbox."
  type        = string
  default     = "sandbox"
}

variable "resource_group_name" {
  description = "Resource group to attach this module's resources to (from module.azure-network)."
  type        = string
}

variable "location" {
  description = "Azure region to attach this module's resources to (from module.azure-network)."
  type        = string
}
