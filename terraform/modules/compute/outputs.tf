output "ec2_instance_id" {
  description = "Instance ID of the app EC2 instance."
  value       = aws_instance.app.id
}

output "lambda_arn" {
  description = "ARN of the hello-world Lambda function."
  value       = aws_lambda_function.main.arn
}

output "lambda_name" {
  description = "Name of the Lambda function."
  value       = aws_lambda_function.main.function_name
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.main.arn
}

output "ecs_task_definition_arn" {
  description = "ARN of the ECS task definition."
  value       = aws_ecs_task_definition.main.arn
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "API server endpoint of the EKS cluster."
  value       = aws_eks_cluster.main.endpoint
}
