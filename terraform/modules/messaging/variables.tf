variable "environment" {
  description = "Tag value. Never set to 'prod' for this sandbox."
  type        = string
  default     = "sandbox"
}

variable "kms_key_arn" {
  description = "ARN of the CMK (from modules/security) for SNS topic encryption."
  type        = string
}
