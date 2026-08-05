output "app_role_arn" {
  description = "ARN of the app IAM role."
  value       = aws_iam_role.app.arn
}

output "app_instance_profile_name" {
  description = "Name of the EC2 instance profile for the app role."
  value       = aws_iam_instance_profile.app.name
}

output "kms_key_id" {
  description = "ID of the CMK (KMS key)."
  value       = aws_kms_key.main.key_id
}

output "kms_key_arn" {
  description = "ARN of the CMK."
  value       = aws_kms_key.main.arn
}

output "kms_alias" {
  description = "Alias of the CMK."
  value       = aws_kms_alias.main.name
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret."
  value       = aws_secretsmanager_secret.main.arn
}

output "acm_certificate_arn" {
  description = "ARN of the ACM certificate (DNS validation pending in real AWS)."
  value       = aws_acm_certificate.main.arn
}
