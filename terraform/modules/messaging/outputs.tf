output "sqs_queue_url" {
  description = "URL of the main SQS queue."
  value       = aws_sqs_queue.main.id
}

output "sqs_queue_arn" {
  description = "ARN of the main SQS queue."
  value       = aws_sqs_queue.main.arn
}

output "dlq_queue_url" {
  description = "URL of the dead-letter queue."
  value       = aws_sqs_queue.dlq.id
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic."
  value       = aws_sns_topic.main.arn
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge scheduled rule."
  value       = aws_cloudwatch_event_rule.main.arn
}

output "sfn_state_machine_arn" {
  description = "ARN of the Step Functions state machine."
  value       = aws_sfn_state_machine.main.arn
}
