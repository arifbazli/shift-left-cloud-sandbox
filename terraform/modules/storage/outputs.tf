output "artifacts_bucket" {
  description = "Name of the S3 artifacts bucket."
  value       = aws_s3_bucket.artifacts.bucket
}

output "artifacts_bucket_arn" {
  description = "ARN of the S3 artifacts bucket."
  value       = aws_s3_bucket.artifacts.arn
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table."
  value       = aws_dynamodb_table.main.name
}

output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB table."
  value       = aws_dynamodb_table.main.arn
}

output "dynamodb_stream_arn" {
  description = "ARN of the DynamoDB stream (for Lambda/EventBridge trigger)."
  value       = aws_dynamodb_table.main.stream_arn
}
