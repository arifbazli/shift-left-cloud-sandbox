# =============================================================================
# terraform/outputs.tf — one block per module
# =============================================================================
# These outputs are read by scripts/deploy.sh (captured as JSON) and consumed
# by scripts/verify.sh to independently verify resources in floci-core.
# Existing output names (vpc_id, private_subnet_id, artifacts_bucket,
# app_security_group_id, app_role_arn) are preserved for backward compatibility.
# =============================================================================

# ── network ──────────────────────────────────────────────────────────────────
output "vpc_id" {
  description = "ID of the main VPC."
  value       = module.network.vpc_id
}

output "private_subnet_id" {
  description = "ID of the private subnet."
  value       = module.network.private_subnet_id
}

output "app_security_group_id" {
  description = "ID of the app-tier security group."
  value       = module.network.app_security_group_id
}

output "flow_logs_bucket" {
  description = "Name of the VPC flow logs bucket."
  value       = module.network.flow_logs_bucket
}

# ── storage ───────────────────────────────────────────────────────────────────
output "artifacts_bucket" {
  description = "Name of the S3 artifacts bucket."
  value       = module.storage.artifacts_bucket
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table."
  value       = module.storage.dynamodb_table_name
}

output "dynamodb_stream_arn" {
  description = "ARN of the DynamoDB stream."
  value       = module.storage.dynamodb_stream_arn
}

# ── security ──────────────────────────────────────────────────────────────────
output "app_role_arn" {
  description = "ARN of the app IAM role."
  value       = module.security.app_role_arn
}

output "kms_key_id" {
  description = "ID of the sandbox CMK."
  value       = module.security.kms_key_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret."
  value       = module.security.secret_arn
}

# ── compute ───────────────────────────────────────────────────────────────────
output "ec2_instance_id" {
  description = "Instance ID of the app EC2 instance."
  value       = module.compute.ec2_instance_id
}

output "lambda_arn" {
  description = "ARN of the hello-world Lambda function."
  value       = module.compute.lambda_arn
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = module.compute.ecs_cluster_arn
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.compute.eks_cluster_name
}

# ── messaging ─────────────────────────────────────────────────────────────────
output "sqs_queue_url" {
  description = "URL of the main SQS queue."
  value       = module.messaging.sqs_queue_url
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic."
  value       = module.messaging.sns_topic_arn
}

output "sfn_state_machine_arn" {
  description = "ARN of the Step Functions state machine."
  value       = module.messaging.sfn_state_machine_arn
}

# ── data ──────────────────────────────────────────────────────────────────────
output "db_endpoint" {
  description = "RDS PostgreSQL endpoint."
  value       = module.data.db_endpoint
}

output "msk_cluster_arn" {
  description = "ARN of the MSK cluster."
  value       = module.data.msk_cluster_arn
}

output "opensearch_endpoint" {
  description = "OpenSearch domain endpoint."
  value       = module.data.opensearch_endpoint
}

# ── api ───────────────────────────────────────────────────────────────────────
output "api_id" {
  description = "ID of the API Gateway REST API."
  value       = module.api.api_id
}

output "api_log_group" {
  description = "Name of the API Gateway access log group."
  value       = module.api.log_group_name
}
