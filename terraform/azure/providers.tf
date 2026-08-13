# =============================================================================
# Shift-Left Cloud Security Sandbox - floci-stack/terraform/azure/providers.tf
# =============================================================================
# PURPOSE
#   Provider configuration for the Azure (floci-az) module tree. Applied
#   against floci-az (localhost:4577) ONLY — no real Azure contact. This is
#   a SEPARATE root from terraform/ (AWS) — own state, own provider, own
#   apply lifecycle. terraform/main.tf's existing AWS-only `deploy.sh` runs
#   are completely unaffected by anything in this directory.
#
# WHY A SEPARATE ROOT, NOT A SHARED ONE WITH AWS
#   terraform/'s existing full `terraform apply` (scripts/deploy.sh) would
#   otherwise try to plan/apply Azure resources on every AWS-only run,
#   requiring floci-az to be running with TLS enabled just to do AWS work.
#   Splitting the root avoids that coupling entirely.
#
# STATE + SECRETS
#   Backend: local (terraform.tfstate in this dir, gitignored).
#   Credentials: floci-az accepts anything (entra/oidc mock does not
#   validate bearer tokens); scripts use fixed dummy IDs, never real ones.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0" # NOT unpinned/>= — v5.x removes skip_provider_registration
                          # and other 4.x-line arguments. ~> 4.0 (v4.81.0 at time of
                          # writing) is the line confirmed working end-to-end
                          # (terraform init + plan against a real floci-az
                          # container) during this session's verification.
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # Local-only crypto (generates a throwaway SSH key for
                          # modules/azure-compute's mocked VM) — no network calls,
                          # no floci-az interaction, no real credential material.
    }
  }

  # SEC_INTENT: local-only backend. State never leaves the sandbox. Separate
  # file from terraform/terraform.tfstate (AWS) — see PURPOSE above.
  backend "local" {
    path = "terraform.tfstate"
  }
}

# SEC_INTENT: endpoint is floci-az at var.floci_az_endpoint, NOT real Azure.
#
# Unlike the aws provider's dynamic "endpoints" block (per-service HTTP
# overrides), azurerm has no per-service endpoint mechanism at all — the
# whole provider is redirected via `environment`/`metadata_host`, the same
# mechanism real Azure Stack / sovereign-cloud deployments use: Terraform
# calls GET https://<metadata_host>/metadata/endpoints to discover where
# every other endpoint (resource manager, login, graph, ...) actually lives.
#
# CONFIRMED (this session, live tests against docker.io/floci/floci-az,
# re-verified against this exact file content before it was written):
#   `terraform init` + `terraform plan` both succeeded end-to-end with this
#   exact provider shape.
#
# TLS IS MANDATORY, NOT OPTIONAL — different from AWS's plain-HTTP
# endpoints{} block. The provider's metadata discovery call is HTTPS-only
# with no HTTP fallback; floci-az must be started with
# FLOCI_AZ_TLS_ENABLED=true (see podman-compose.yml / scripts/start-floci-az.sh)
# or `terraform init` fails before sending a single resource request.
#
# NO INSECURE/SKIP-VERIFY OPTION EXISTS on this provider, and none is used
# here — checked directly: azurerm has no insecure-skip-tls-verify-style
# argument for the ARM endpoint (unlike e.g. the kubernetes/helm providers).
# The self-signed cert floci-az generates must be genuinely trusted by
# whatever process runs terraform — confirmed working via SSL_CERT_FILE
# pointed at the cert fetched from floci-az's /_floci/tls-cert endpoint,
# NOT a bypass. That fetch/trust step lives in whatever invokes terraform
# against this root (e.g. a future deploy-azure.sh / grow-stack-azure.sh),
# not here — this file only describes where the provider points, not how
# the caller trusts its cert.
provider "azurerm" {
  features {}
  use_cli = false

  environment   = var.floci_az_enabled ? "stack" : "public"
  metadata_host = var.floci_az_enabled ? var.floci_az_endpoint : null

  # floci-az's entra/oidc mock does not validate bearer tokens
  # ("validate-tokens:false") — any well-formed dummy values work. Same
  # dummy subscription/tenant IDs floci-az itself vends by default.
  # NOTE: unconditional, same scope as terraform/providers.tf's aws
  # provider leaving access_key/secret_key = "test" unconditional too —
  # flipping floci_az_enabled to false does not make this point at real
  # Azure; only the endpoint discovery is actually toggled.
  subscription_id = "00000000-0000-0000-0000-000000000001"
  tenant_id       = "00000000-0000-0000-0000-000000000002"
  client_id       = "00000000-0000-0000-0000-000000000003"
  client_secret   = "fake-secret"
}
