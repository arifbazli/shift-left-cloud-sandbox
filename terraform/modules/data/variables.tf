variable "environment" {
  description = "Tag value. Never set to 'prod' for this sandbox."
  type        = string
  default     = "sandbox"
}

variable "subnet_id" {
  description = "Private subnet ID from modules/network (single AZ: us-east-1a)."
  type        = string
}

variable "security_group_id" {
  description = "App SG ID from modules/network."
  type        = string
}

variable "db_password" {
  description = "RDS master password (sandbox only — never set this in production tfvars)."
  type        = string
  default     = "floci-changeme"
  sensitive   = true
}

variable "kms_key_arn" {
  description = "ARN of the CMK (from modules/security) for MSK at-rest encryption."
  type        = string
}
