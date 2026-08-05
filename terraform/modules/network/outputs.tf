output "vpc_id" {
  description = "ID of the main VPC."
  value       = aws_vpc.main.id
}

output "private_subnet_id" {
  description = "ID of the private subnet (single AZ: us-east-1a)."
  value       = aws_subnet.private.id
}

output "app_security_group_id" {
  description = "ID of the app-tier security group."
  value       = aws_security_group.app.id
}

output "flow_logs_role_arn" {
  description = "ARN of the VPC flow logs IAM role."
  value       = aws_iam_role.flow_logs.arn
}

output "flow_logs_bucket" {
  description = "Name of the VPC flow logs S3 bucket."
  value       = aws_s3_bucket.flow_logs.bucket
}
