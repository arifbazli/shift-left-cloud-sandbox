# =============================================================================
# modules/messaging/main.tf
# =============================================================================
# Resources: SQS queue, SNS topic, EventBridge rule, Step Functions state machine.
# All minimal viable config, single region.
#
# Invoke-time APIs NOT represented here (no Terraform resource):
#   - SQS SendMessage / ReceiveMessage / DeleteMessage
#   - SNS Publish
#   - EventBridge PutEvents
#   - Step Functions StartExecution / StopExecution
# =============================================================================

# -----------------------------------------------------------------------------
# SQS Queue
# SEC_INTENT: SQS-managed SSE (no CMK required) satisfies encryption-at-rest.
# Visibility timeout and message retention are minimal for the sandbox.
# Dead-letter queue captures failed message processing for investigation.
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "dlq" {
  name                      = "floci-dlq-${var.environment}"
  message_retention_seconds = 1209600 # 14 days — maximum DLQ retention
  sqs_managed_sse_enabled   = true    # SEC_INTENT: SQS-managed encryption (AVD-AWS-0015)

  tags = {
    Name        = "floci-dlq"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "main" {
  name                       = "floci-queue-${var.environment}"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400 # 1 day for sandbox
  sqs_managed_sse_enabled    = true  # SEC_INTENT: SQS-managed encryption (AVD-AWS-0015)

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3 # SEC_INTENT: move to DLQ after 3 failed attempts
  })

  tags = {
    Name        = "floci-queue"
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# SNS Topic
# SEC_INTENT: topic is not publicly subscribable — no resource policy that
# allows "*" principal. KMS encryption uses the AWS-managed SNS key
# (alias/aws/sns) which avoids needing a customer CMK in floci.
# tfsec:ignore:AVD-AWS-0031 floci KMS limited; aws/sns managed key used.
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "main" {
  name = "floci-events-${var.environment}"

  # SEC_INTENT: CMK encryption passed from modules/security (AVD-AWS-0136).
  kms_master_key_id = var.kms_key_arn

  tags = {
    Name        = "floci-events"
    Environment = var.environment
  }
}

# SEC_INTENT: SQS subscription with raw message delivery. The queue policy
# (below) restricts subscription to only this topic ARN.
resource "aws_sns_topic_subscription" "sqs" {
  topic_arn = aws_sns_topic.main.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.main.arn

  raw_message_delivery = true # SEC_INTENT: raw delivery avoids JSON double-encoding
}

resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowSNSPublish"
      Effect = "Allow"
      # SEC_INTENT: principal is scoped to this specific SNS topic, not "*".
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.main.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.main.arn }
      }
    }]
  })
}

# -----------------------------------------------------------------------------
# EventBridge Rule
# SEC_INTENT: rule is DISABLED by default in the sandbox so it does not fire
# unintentionally. schedule_expression uses rate() — no cron with broad
# wildcard patterns that could cause unexpected invocations.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "main" {
  name        = "floci-events-${var.environment}"
  description = "Demo scheduled rule — fires every 5 minutes (DISABLED in sandbox)"

  schedule_expression = "rate(5 minutes)"
  state               = "DISABLED" # SEC_INTENT: disabled by default; enable explicitly

  tags = {
    Name        = "floci-events-rule"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_event_target" "sqs" {
  rule      = aws_cloudwatch_event_rule.main.name
  target_id = "SendToSQS"
  arn       = aws_sqs_queue.main.arn
}

# -----------------------------------------------------------------------------
# Step Functions State Machine
# SEC_INTENT: logging ALL states to CloudWatch (not ERROR-only) so the full
# execution path is auditable. X-Ray tracing enabled. The execution role is
# scoped to CloudWatch Logs write only — no broad permissions.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn_exec" {
  name               = "floci-sfn-exec-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

data "aws_iam_policy_document" "sfn_logs" {
  statement {
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"] # tfsec:ignore:AVD-AWS-0057 CW Logs delivery API requires *
  }
}

resource "aws_iam_role_policy" "sfn_logs" {
  name   = "floci-sfn-logs"
  role   = aws_iam_role.sfn_exec.id
  policy = data.aws_iam_policy_document.sfn_logs.json
}

# tfsec:ignore:AVD-AWS-0017 floci has no KMS for CW Logs; production uses CMK.
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/floci-workflow-${var.environment}"
  retention_in_days = 30 # SEC_INTENT: 30-day retention; production >= 90 days

  # tfsec:ignore:AVD-AWS-0017 see above.
}

resource "aws_sfn_state_machine" "main" {
  name     = "floci-workflow-${var.environment}"
  role_arn = aws_iam_role.sfn_exec.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "Minimal demo workflow — Pass state only"
    StartAt = "HelloWorld"
    States = {
      HelloWorld = {
        Type   = "Pass"
        Result = "floci-hello"
        End    = true
      }
    }
  })

  logging_configuration {
    level                  = "ALL" # SEC_INTENT: all states logged (not ERROR-only)
    include_execution_data = false # SEC_INTENT: do not log payload data
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
  }

  tracing_configuration {
    enabled = true # SEC_INTENT: X-Ray end-to-end tracing
  }

  tags = {
    Name        = "floci-workflow"
    Environment = var.environment
  }

  depends_on = [aws_iam_role_policy.sfn_logs]
}
