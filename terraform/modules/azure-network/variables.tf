variable "environment" {
  description = "Tag value. Never set to 'prod' for this sandbox."
  type        = string
  default     = "sandbox"
}

variable "vnet_cidr" {
  description = "CIDR block for the VNet."
  type        = string
  default     = "10.0.0.0/16"
}
