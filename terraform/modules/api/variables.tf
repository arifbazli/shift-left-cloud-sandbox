variable "environment" {
  description = "Tag value. Never set to 'prod' for this sandbox."
  type        = string
  default     = "sandbox"
}

variable "lambda_arn" {
  description = "ARN of the Lambda function from modules/compute (used as API GW integration)."
  type        = string
  default     = ""
}
