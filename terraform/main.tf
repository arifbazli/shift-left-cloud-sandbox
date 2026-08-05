# =============================================================================
# terraform/main.tf — root module (module calls only)
# =============================================================================
# This file wires the 7 feature modules together. There are NO inline resource
# blocks here — all resources live in modules/. This keeps the root readable
# and makes per-module tfsec scans clean.
#
# Invoke-time APIs with NO Terraform resource (listed here for completeness):
#   - Lambda function invocations (aws lambda invoke)
#   - SQS SendMessage / ReceiveMessage / DeleteMessage
#   - SNS Publish
#   - EventBridge PutEvents
#   - Step Functions StartExecution / StopExecution / DescribeExecution
#   - MSK Kafka producer / consumer connections (Kafka client protocol)
#   - ElastiCache Redis commands (RESP protocol)
#   - OpenSearch document indexing / query (REST _bulk / _search)
#   - RDS SQL connections (pg / mysql driver)
#
# Demo fixture toggle: scripts/toggle-fixture.sh on|off
#   operates on:      terraform/modules/security/main.tf
#   snapshots:        terraform/modules/security/main.tf.{with,without}-fixture
# =============================================================================

# ── network ─────────────────────────────────────────────────────────────────
module "network" {
  source      = "./modules/network"
  environment = var.environment
  vpc_cidr    = "10.0.0.0/16"
}

# ── storage ─────────────────────────────────────────────────────────────────
module "storage" {
  source      = "./modules/storage"
  environment = var.environment
}

# ── security ─────────────────────────────────────────────────────────────────
module "security" {
  source               = "./modules/security"
  environment          = var.environment
  artifacts_bucket_arn = module.storage.artifacts_bucket_arn
}

# ── compute ─────────────────────────────────────────────────────────────────
module "compute" {
  source               = "./modules/compute"
  environment          = var.environment
  vpc_id               = module.network.vpc_id
  subnet_id            = module.network.private_subnet_id
  security_group_id    = module.network.app_security_group_id
  app_instance_profile = module.security.app_instance_profile_name
  artifacts_bucket     = module.storage.artifacts_bucket
  kms_key_arn          = module.security.kms_key_arn
}

# ── messaging ────────────────────────────────────────────────────────────────
module "messaging" {
  source      = "./modules/messaging"
  environment = var.environment
  kms_key_arn = module.security.kms_key_arn
}

# ── data ─────────────────────────────────────────────────────────────────────
module "data" {
  source            = "./modules/data"
  environment       = var.environment
  subnet_id         = module.network.private_subnet_id
  security_group_id = module.network.app_security_group_id
  kms_key_arn       = module.security.kms_key_arn
}

# ── api ──────────────────────────────────────────────────────────────────────
module "api" {
  source      = "./modules/api"
  environment = var.environment
  lambda_arn  = module.compute.lambda_arn
}
