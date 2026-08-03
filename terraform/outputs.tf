output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "app_role_arn" {
  value = aws_iam_role.app.arn
}
