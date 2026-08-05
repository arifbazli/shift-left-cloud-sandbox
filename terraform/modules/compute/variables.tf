variable "environment" {
  description = "Tag value. Never set to 'prod' for this sandbox."
  type        = string
  default     = "sandbox"
}

variable "vpc_id" {
  description = "VPC ID from modules/network."
  type        = string
}

variable "subnet_id" {
  description = "Private subnet ID from modules/network (single AZ: us-east-1a)."
  type        = string
}

variable "security_group_id" {
  description = "App SG ID from modules/network."
  type        = string
}

variable "app_instance_profile" {
  description = "EC2 instance profile name from modules/security."
  type        = string
}

variable "artifacts_bucket" {
  description = "Name of the S3 artifacts bucket from modules/storage."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the CMK (from modules/security) for EKS secret encryption."
  type        = string
}
