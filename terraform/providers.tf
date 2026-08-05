# =============================================================================
# Shift-Left Cloud Security Sandbox - floci-stack/terraform/providers.tf
# =============================================================================
# PURPOSE
#   Provider configuration for the expanded 7-module terraform layout.
#   Applied against floci-core (localhost:4566) ONLY — no real AWS contact.
#
# WHY THIS EXISTS
#   Each module carries security-intent comments. Most resources are
#   intentionally tight-by-default. ONE resource in modules/security/ carries
#   a deliberate bad config (the fixture) so the tfsec gate has something
#   real to catch. That bad config is TEST FIXTURE, not advice.
#
# STATE + SECRETS
#   Backend: local (terraform.tfstate in this dir, gitignored).
#   Credentials: floci accepts anything; scripts use `test`/`test`.
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

  # SEC_INTENT: local-only backend. State never leaves the sandbox.
  backend "local" {
    path = "terraform.tfstate"
  }
}

# SEC_INTENT: endpoint is floci at localhost:4566, NOT real AWS.
# skip_credentials_validation + skip_metadata_api_check are required because
# floci does not implement IAM. path-style addressing required for S3.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  s3_use_path_style           = true

  # Override ALL service endpoints to floci when localstack_enabled = true.
  # New services added for the 7-module layout (storage, compute, messaging,
  # data, security, api modules each add endpoint entries here).
  dynamic "endpoints" {
    for_each = var.localstack_enabled ? [1] : []
    content {
      # ── existing ──────────────────────────────────────────────────────────
      s3  = var.localstack_endpoint
      ec2 = var.localstack_endpoint
      iam = var.localstack_endpoint
      sts = var.localstack_endpoint

      # ── storage ───────────────────────────────────────────────────────────
      dynamodb = var.localstack_endpoint

      # ── compute ───────────────────────────────────────────────────────────
      lambda = var.localstack_endpoint
      ecs    = var.localstack_endpoint
      eks    = var.localstack_endpoint

      # ── messaging ─────────────────────────────────────────────────────────
      sqs = var.localstack_endpoint
      sns = var.localstack_endpoint
      sfn = var.localstack_endpoint # Step Functions

      # ── data ──────────────────────────────────────────────────────────────
      rds         = var.localstack_endpoint
      elasticache = var.localstack_endpoint
      kafka       = var.localstack_endpoint # MSK
      opensearch  = var.localstack_endpoint
      es          = var.localstack_endpoint # OpenSearch legacy alias

      # ── security ──────────────────────────────────────────────────────────
      kms            = var.localstack_endpoint
      secretsmanager = var.localstack_endpoint
      acm            = var.localstack_endpoint

      # ── api ───────────────────────────────────────────────────────────────
      apigateway   = var.localstack_endpoint
      cloudwatch   = var.localstack_endpoint
      cloudwatchlogs = var.localstack_endpoint

      # ── shared/events ─────────────────────────────────────────────────────
      eventbridge = var.localstack_endpoint
    }
  }
}
