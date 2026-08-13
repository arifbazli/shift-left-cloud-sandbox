# =============================================================================
# modules/azure-storage/main.tf
# =============================================================================
# Resources: Storage Account + Blob Container (S3 equivalent), Storage Table
# (DynamoDB equivalent). Mirrors modules/storage/'s AWS shape.
#
# CONFIRMED GAP (2026-08-13, apply-level, not a coverage gap): the storage
# ACCOUNT applies cleanly (confirmed via a real apply — slow, ~3 minutes,
# but succeeds). The blob CONTAINER and the TABLE below do not — a real
# `terraform apply` hangs on both indefinitely, with ZERO corresponding
# request ever appearing in floci-az's own logs, confirming the hang is
# client-side, before any request is even sent.
#
# Root cause, confirmed directly: floci-az's ARM response for a storage
# account returns real-Azure-shaped data-plane endpoints —
# `"blob": "http://<account>.blob.core.windows.net/"` — not a
# self-referential floci-az URL. The azurerm provider takes this at face
# value for azurerm_storage_container/azurerm_storage_table (both are
# data-plane resources with no connection-string-override mechanism,
# unlike the Storage SDKs' explicit BlobEndpoint=/TableEndpoint=
# connection-string pattern floci-az's own docs rely on). Those hostnames
# don't resolve to floci-az — confirmed via a direct DNS lookup returning
# NXDOMAIN — so the provider hangs waiting on a connection that never
# completes. No per-resource or provider-level endpoint override exists on
# the real azurerm provider for this (a known limitation independent of
# floci-az, also hit against Azurite). A wildcard-DNS + Host-header
# workaround is theoretically possible (floci-az's blob.md confirms it
# honors the Host header for account-style hostnames) but needs real
# host-level DNS infrastructure, not a documented, supported mechanism —
# out of scope for this module. Kept in code rather than removed, same
# visible-stall-over-silent-skip philosophy as AWS's EKS/MSK findings.
# =============================================================================

# -----------------------------------------------------------------------------
# Storage Account + Blob Container
# SEC_INTENT: mirrors modules/storage's aws_s3_bucket.artifacts — private
# container, TLS-only traffic, public blob access disabled, versioning on.
# -----------------------------------------------------------------------------
resource "azurerm_storage_account" "main" {
  # Storage account names: lowercase alphanumeric only, <=24 chars — real
  # Azure constraint, enforced client-side by the provider regardless of
  # what floci-az itself would accept. var.environment is validated in
  # variables.tf to keep this name under the limit.
  name                = "flociartifacts${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = "Standard"
  account_replication_type = "LRS"

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false # SEC_INTENT: mirrors aws_s3_bucket_public_access_block.artifacts

  blob_properties {
    versioning_enabled = true # SEC_INTENT: mirrors aws_s3_bucket_versioning.artifacts
  }

  tags = {
    Name        = "floci-artifacts"
    Environment = var.environment
  }
}

resource "azurerm_storage_container" "artifacts" {
  name                  = "artifacts"
  storage_account_name  = azurerm_storage_account.main.name
  container_access_type = "private"
}

# -----------------------------------------------------------------------------
# Storage Table (DynamoDB equivalent)
# SEC_INTENT: mirrors modules/storage's aws_dynamodb_table.main. One real
# API-shape difference, not a coverage gap: Table Storage has no per-table
# PITR toggle the way DynamoDB does — encryption-at-rest is account-level
# and always on, with no table-level knob to turn on. Nothing to configure
# here; noted so the difference is visible rather than silently absent.
# -----------------------------------------------------------------------------
resource "azurerm_storage_table" "main" {
  name                 = "flociitems${var.environment}"
  storage_account_name = azurerm_storage_account.main.name
}
