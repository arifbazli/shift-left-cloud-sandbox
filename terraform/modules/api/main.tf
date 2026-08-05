# =============================================================================
# modules/api/main.tf
# =============================================================================
# Resources: API Gateway REST API, CloudWatch Log Group, CloudWatch Metric Alarm.
# =============================================================================

# -----------------------------------------------------------------------------
# CloudWatch Log Group (for API Gateway access logs)
# SEC_INTENT: 30-day retention. Encryption note: floci does not expose KMS for
# CW Logs — in production this group would use a CMK (kms_key_id).
# tfsec:ignore:AVD-AWS-0017 floci has no KMS for CW Logs; CMK in production.
# -----------------------------------------------------------------------------
# tfsec:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/floci-api-${var.environment}"
  retention_in_days = 30 # SEC_INTENT: 30-day retention; production >= 90 days

  # tfsec:ignore:AVD-AWS-0017 see module header.
}

# -----------------------------------------------------------------------------
# API Gateway REST API
# SEC_INTENT: REGIONAL endpoint (not EDGE) keeps traffic within the VPC
# boundary and avoids CloudFront as an implicit data-plane. Access logging
# enabled with the CloudWatch log group above.
# -----------------------------------------------------------------------------
resource "aws_api_gateway_rest_api" "main" {
  name        = "floci-api-${var.environment}"
  description = "Shift-left sandbox REST API"

  endpoint_configuration {
    types = ["REGIONAL"] # SEC_INTENT: REGIONAL — no implicit CloudFront exposure
  }

  tags = {
    Name        = "floci-api"
    Environment = var.environment
  }
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  triggers = {
    redeployment = sha1(jsonencode(aws_api_gateway_rest_api.main.body))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "main" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = var.environment

  # SEC_INTENT: access logging to the dedicated CW log group.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    # SEC_INTENT: log full CLF format; switch to JSON in production for SIEM ingestion.
    format = "$context.identity.sourceIp $context.requestId $context.httpMethod $context.path $context.status"
  }

  xray_tracing_enabled = true # SEC_INTENT: X-Ray end-to-end tracing

  tags = {
    Name        = "floci-api-stage"
    Environment = var.environment
  }
}

# SEC_INTENT: enforce TLS 1.2 minimum on the stage — no TLS 1.0/1.1.
resource "aws_api_gateway_domain_name" "main" {
  domain_name              = "api-floci-${var.environment}.example.internal"
  regional_certificate_arn = "" # populated in real deploys from modules/security acm arn

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  # SEC_INTENT: TLS 1.2 minimum (AVD-AWS-0190 / AVD-AWS-0004)
  security_policy = "TLS_1_2"
}

# -----------------------------------------------------------------------------
# CloudWatch Metric Alarm
# SEC_INTENT: alert on API Gateway 5xx error rate. In the sandbox this alarm
# only writes to the log group; a real org would wire it to an SNS topic with
# a PagerDuty/Opsgenie subscriber.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "floci-api-5xx-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5XXError"
  namespace           = "AWS/ApiGateway"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "API Gateway 5xx error rate above threshold (sandbox monitoring)"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiName = aws_api_gateway_rest_api.main.name
    Stage   = var.environment
  }

  tags = {
    Name        = "floci-api-5xx"
    Environment = var.environment
  }
}
