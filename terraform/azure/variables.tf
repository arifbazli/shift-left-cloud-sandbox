# =============================================================================
# variables.tf
# SEC_INTENT: mirrors terraform/variables.tf's localstack_enabled/
# localstack_endpoint pattern — a knob that lets scripts/CI flip "we are
# talking to floci-az" vs "we are talking to real Azure" without editing
# code. Default is floci-az.
# =============================================================================

variable "floci_az_enabled" {
  description = "When true, the azurerm provider targets floci-az at var.floci_az_endpoint instead of real Azure."
  type        = bool
  default     = true
}

variable "floci_az_endpoint" {
  description = "host:port for floci-az's Azure Stack metadata endpoint. Only consulted when floci_az_enabled=true. Requires floci-az started with FLOCI_AZ_TLS_ENABLED=true — see scripts/start-floci-az.sh."
  type        = string
  default     = "localhost:4577"
}

variable "environment" {
  description = "Tag value. Never set to 'prod' for this sandbox."
  type        = string
  default     = "sandbox"
}
