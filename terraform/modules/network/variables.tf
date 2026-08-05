variable "environment" {
  description = "Tag value. Never set to 'prod' for this sandbox."
  type        = string
  default     = "sandbox"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}
