# =============================================================================
# modules/storage/main.tf
# =============================================================================
# Resources: S3 artifacts bucket (relocated from root), DynamoDB table (new).
# =============================================================================

# -----------------------------------------------------------------------------
# S3 Artifacts Bucket
# SEC_INTENT: private bucket, encryption enforced, versioning on,
# public access blocked. tfsec should be silent on this resource.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket = "floci-artifacts-${var.environment}"
  tags = {
    Name        = "floci-artifacts"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# tfsec:ignore:AVD-AWS-0132 floci has no KMS; production uses CMK with rotation.
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SEC_INTENT: bucket logging to a dedicated prefix in the same bucket.
# A real org would log to a separate central audit bucket.
# tfsec:ignore:AVD-AWS-0089 logging target is same bucket (acceptable in sandbox)
resource "aws_s3_bucket_logging" "artifacts" {
  bucket        = aws_s3_bucket.artifacts.id
  target_bucket = aws_s3_bucket.artifacts.id
  target_prefix = "access-log/"
}

# -----------------------------------------------------------------------------
# DynamoDB Table
# SEC_INTENT: PAY_PER_REQUEST avoids capacity over-provisioning. Streams
# enabled for event-driven consumers (Lambda, EventBridge Pipes). SSE is
# always-on in AWS; this block makes the intent explicit.
# PITR enabled for point-in-time recovery — guards against accidental deletes.
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "main" {
  name         = "floci-items-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES" # SEC_INTENT: full before/after for audit trail

  server_side_encryption {
    enabled = true # SEC_INTENT: AWS-managed key; production uses CMK via kms_key_arn
  }

  point_in_time_recovery {
    enabled = true # SEC_INTENT: PITR protects against data-loss events
  }

  tags = {
    Name        = "floci-items"
    Environment = var.environment
  }
}
