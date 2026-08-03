# =============================================================================
# variables.tf
# SEC_INTENT: knobs that let the agent-loop / CI flip "we are talking to floci"
# vs "we are talking to real AWS" without editing code. Default is floci.
# =============================================================================

variable "localstack_enabled" {
  description = "When true, the AWS provider targets floci/localstack at var.localstack_endpoint instead of real AWS."
  type        = bool
  default     = true
}

variable "localstack_endpoint" {
  description = "Base URL for floci/localstack. Only consulted when localstack_enabled=true."
  type        = string
  default     = "http://localhost:4566"
}

variable "environment" {
  description = "Tag value. Never set to 'prod' for this sandbox."
  type        = string
  default     = "sandbox"
}
