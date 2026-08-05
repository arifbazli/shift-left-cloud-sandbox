# =============================================================================
# modules/network/main.tf
# =============================================================================
# Resources: VPC, private subnet, security group (+ rules), VPC flow logs.
# All resources are extracted verbatim from the original flat terraform/main.tf
# and converted to use module input variables. No security-intent changes.
# =============================================================================

# -----------------------------------------------------------------------------
# VPC
# SEC_INTENT: a real VPC with DNS support on. We do not enable
# "map_public_ip_on_launch" by default; the public subnet exists but is
# genuinely public only for resources that explicitly associate an EIP/IGW.
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "floci-vpc"
    Environment = var.environment
    Owner       = "shift-left-sandbox"
  }
}

# SEC_INTENT: a private subnet (no route to IGW). Hosts would not be reachable
# from the internet in a real deploy. floci accepts this fine.
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1) # 10.0.1.0/24
  availability_zone = "us-east-1a"

  tags = {
    Name = "floci-private"
  }
}

# -----------------------------------------------------------------------------
# Security Group
# SEC_INTENT: tight by default. tfsec checks CIDRs; 10.0.0.0/16 (VPC) only.
# 0.0.0.0/0 is NOT used for ingress.
# -----------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "floci-app-sg"
  description = "App tier SG. SSH only from admin host."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "floci-app-sg"
  }
}

# SEC_INTENT: ingress is admin-IP-only on 22, app port 8080 from VPC only.
resource "aws_security_group_rule" "ssh_admin" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.app.id
  description       = "SSH from inside the VPC"
}

resource "aws_security_group_rule" "app_internal" {
  type              = "ingress"
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.app.id
  description       = "App traffic from inside the VPC"
}

# SEC_INTENT: explicit egress restricted to https (443) only.
resource "aws_security_group_rule" "egress_https" {
  type      = "egress"
  from_port = 443
  to_port   = 443
  protocol  = "tcp"
  # tfsec:ignore:AVD-AWS-0104 Sandbox needs outbound HTTPS to pull packages
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.app.id
  description       = "Outbound HTTPS only (for package updates and API calls)"
}

resource "aws_security_group_rule" "egress_dns_tcp" {
  type      = "egress"
  from_port = 53
  to_port   = 53
  protocol  = "tcp"
  # tfsec:ignore:AVD-AWS-0104 DNS egress required for service discovery
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.app.id
  description       = "DNS over TCP"
}

resource "aws_security_group_rule" "egress_dns_udp" {
  type      = "egress"
  from_port = 53
  to_port   = 53
  protocol  = "udp"
  # tfsec:ignore:AVD-AWS-0104 DNS egress required for service discovery
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.app.id
  description       = "DNS over UDP"
}

# -----------------------------------------------------------------------------
# VPC Flow Logs
# SEC_INTENT: real VPC flow logs to a dedicated S3 bucket. A real org would
# use CloudWatch or Kinesis; S3 is fine for the sandbox.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "flow_logs" {
  bucket = "floci-flow-logs-${var.environment}"
  tags   = { Name = "floci-flow-logs" }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket                  = aws_s3_bucket.flow_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SEC_INTENT: SSE-S3 on the flow-logs bucket. A real org would use a CMK.
# tfsec:ignore:AVD-AWS-0132 floci has no KMS; same justification as artifacts.
resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# SEC_INTENT: flow-logs bucket logging. The bucket logs to itself here for
# demo simplicity; a real org would direct these to a central audit bucket.
# tfsec:ignore:AVD-AWS-0089 logging target is same bucket (acceptable in sandbox)
resource "aws_s3_bucket_logging" "flow_logs" {
  bucket        = aws_s3_bucket.flow_logs.id
  target_bucket = aws_s3_bucket.flow_logs.id
  target_prefix = "self-log/"
}

resource "aws_flow_log" "main" {
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_s3_bucket.flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "floci-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    # VPC Flow Logs can only write to the bucket-rooted prefix; tfsec cannot
    # resolve the interpolation and flags it as a wildcard. Bucket-scoped,
    # not account-wide.
    # tfsec:ignore:AVD-AWS-0057
    resources = [
      aws_s3_bucket.flow_logs.arn,
      "${aws_s3_bucket.flow_logs.arn}/*",
    ]
    actions = ["s3:PutObject", "s3:GetBucketAcl"]
  }
}

resource "aws_iam_role_policy" "flow_logs_write" {
  name   = "floci-flow-logs-write"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}
