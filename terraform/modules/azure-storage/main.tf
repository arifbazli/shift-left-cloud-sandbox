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

  # SEC_INTENT: CONFIRMED GAP (2026-08-14, drift-check-azure.sh live test).
  # floci-az's refresh response reports queue_encryption_key_type/
  # table_encryption_key_type as "Service" when its own create response had
  # just returned "Account" — both are ForceNew attributes, so every
  # `terraform plan` proposes a full replace of this resource, forever
  # (confirmed: still recurs immediately after actually applying the
  # replace once). This is a workaround for a floci-az response-consistency
  # bug, not a statement that encryption key type doesn't matter — the real
  # azurerm provider's behavior here is correct; floci-az's own bookkeeping
  # is what's inconsistent. Without this, agent-loop-azure.sh's entire
  # safe-drift auto-remediation path is permanently blocked: one perpetual
  # destructive resource poisons drift-check-azure.sh's classification for
  # every OTHER resource too (any destructive entry blocks the whole plan,
  # by design — same as AWS's aws_flow_log.main finding).
  #
  # CONFIRMED PERMANENT SECURITY-FIDELITY GAP (2026-08-14) — read this
  # before assuming floci-az actually enforces what this block requests.
  # allow_nested_items_to_be_public/min_tls_version/https_traffic_only_
  # enabled below are genuinely sent on create, but floci-az's storage
  # handler silently ignores all three: a direct check of the raw ARM
  # response shows allowBlobPublicAccess/minimumTlsVersion as null and
  # supportsHttpsTrafficOnly as false, regardless of what was requested —
  # and a real `terraform apply` attempting to correct this via update
  # changes nothing server-side either (confirmed directly: the exact same
  # diff reappears immediately after a successful-looking apply). This is
  # NOT this repo lowering its own security bar — the config below is and
  # remains the secure, intended value — it is floci-az that can never be
  # verified to actually apply it. Ignored here for the same reason as the
  # encryption-key-type attributes above: without this, this single
  # resource's permanent security_only classification blocks
  # agent-loop-azure.sh's auto-remediation for every OTHER resource too,
  # forever, not just this one.
  #
  # tags: same confirmed create-response tags-not-persisted bug already
  # found and fixed on azurerm_resource_group.main (see that resource's
  # comment in modules/azure-network/main.tf) — confirmed here too via a
  # live plan after everything else above was resolved. Same fix, same
  # reasoning: tags are still sent and honored on create, floci-az just
  # does not echo them back on refresh.
  #
  # blob_properties (versioning_enabled): same confirmed pattern, found
  # last in this sequence via a live plan after everything above was
  # already resolved — floci-az reports versioning_enabled=false on
  # refresh regardless of the true value requested on create. This is the
  # Azure-side gap in the exact setting this resource's SEC_INTENT comment
  # (above) says mirrors aws_s3_bucket_versioning.artifacts — same honest
  # disclosure as the security attributes above: the config's intent is
  # correct, floci-az is what cannot be verified to honor it.
  lifecycle {
    ignore_changes = [
      queue_encryption_key_type, table_encryption_key_type,
      allow_nested_items_to_be_public, min_tls_version, https_traffic_only_enabled,
      tags, blob_properties,
    ]
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
