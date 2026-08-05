variable "environment" {
  description = "Tag value. Never set to 'prod' for this sandbox."
  type        = string
  default     = "sandbox"
}

variable "artifacts_bucket_arn" {
  description = "ARN of the S3 artifacts bucket (from modules/storage)."
  type        = string
}
