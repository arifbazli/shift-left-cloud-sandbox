output "api_id" {
  description = "ID of the API Gateway REST API."
  value       = aws_api_gateway_rest_api.main.id
}

output "api_name" {
  description = "Name of the API Gateway REST API."
  value       = aws_api_gateway_rest_api.main.name
}

output "stage_invoke_url" {
  description = "Invoke URL for the deployed stage."
  value       = aws_api_gateway_stage.main.invoke_url
}

output "log_group_name" {
  description = "Name of the API Gateway access log group."
  value       = aws_cloudwatch_log_group.api_access.name
}

output "alarm_arn" {
  description = "ARN of the 5xx error CloudWatch alarm."
  value       = aws_cloudwatch_metric_alarm.api_5xx.arn
}
