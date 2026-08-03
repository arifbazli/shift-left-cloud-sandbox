# =============================================================================
# Shift-Left Cloud Security Sandbox - floci-stack/terraform/
# =============================================================================
# PURPOSE
#   A minimal but realistic VPC+S3+IAM+SG shape. Applied against localstack-style
#   floci (localhost:4566) ONLY. The "AWS" provider here is just a target; no real
#   AWS account is ever contacted.
#
# WHY THIS EXISTS
#   Each resource carries a security-intent comment. Most are intentionally
#   tight-by-default. ONE resource (see main.tf) carries a deliberate bad
#   config so the tfsec gate in scripts/scan.sh has something real to catch.
#   That bad config is TEST FIXTURE, not advice — do not copy it elsewhere.
#
# STATE + SECRETS
#   Backend: local (terraform.tfstate in this dir, gitignored).
#   Credentials: floci accepts anything; we use `test`/`test` in scripts/deploy.sh.
#   Real AWS keys are never read.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # SEC_INTENT: local-only backend. State never leaves the sandbox. In a real
  # project this would be S3+DynamoDB or Terraform Cloud with encryption-at-rest
  # and access logging — we deliberately avoid that here to keep the R&D
  # sandbox fully offline.
  backend "local" {
    path = "terraform.tfstate"
  }
}

# SEC_INTENT: endpoint is floci at localhost:4566, NOT real AWS.
# skip_credentials_validation + skip_metadata_api_check are required because
# floci does not implement IAM. We also force path-style addressing and
# disable S3 region checks — floci returns a placeholder region.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  s3_use_path_style           = true

  # Override endpoints only when the TF_ENDPOINT env vars are set
  # (scripts/deploy.sh sets them to http://localhost:4566).
  dynamic "endpoints" {
    for_each = var.localstack_enabled ? [1] : []
    content {
      s3  = var.localstack_endpoint
      ec2 = var.localstack_endpoint
      iam = var.localstack_endpoint
      sts = var.localstack_endpoint
    }
  }
}
