# =============================================================================
# modules/data/main.tf
# =============================================================================
# Resources: RDS (PostgreSQL), ElastiCache (Redis), MSK (Kafka), OpenSearch.
# All: single AZ, minimal tier, encryption enforced.
#
# Apply notes:
#   - RDS, ElastiCache, MSK: supported by floci community.
#   - OpenSearch (aws_opensearch_domain): may require floci Pro or a compatible
#     LocalStack image with the "es" service enabled.
#
# Invoke-time APIs NOT represented here (no Terraform resource):
#   - PostgreSQL connections (pg driver)
#   - Redis commands (RESP protocol)
#   - Kafka producer / consumer (Kafka client)
#   - OpenSearch document indexing / search queries
# =============================================================================

# Subnet group — RDS and ElastiCache both need one.
resource "aws_db_subnet_group" "main" {
  name        = "floci-db-subnet-${var.environment}"
  description = "Subnet group for RDS (single AZ sandbox)"
  subnet_ids  = [var.subnet_id]

  tags = {
    Name        = "floci-db-subnet"
    Environment = var.environment
  }
}

resource "aws_elasticache_subnet_group" "main" {
  name        = "floci-cache-subnet-${var.environment}"
  description = "Subnet group for ElastiCache Redis (single AZ sandbox)"
  subnet_ids  = [var.subnet_id]
}

# -----------------------------------------------------------------------------
# RDS — PostgreSQL
# SEC_INTENT: storage_encrypted = true (AVD-AWS-0077). Not publicly accessible
# (AVD-AWS-0023). In a VPC subnet group (AVD-AWS-0025). Backup retention 7 days.
# deletion_protection = false is acceptable for the sandbox; prod must be true.
# tfsec:ignore:AVD-AWS-0076 sandbox does not need deletion protection.
# -----------------------------------------------------------------------------
resource "aws_db_instance" "main" {
  identifier        = "floci-postgres-${var.environment}"
  engine            = "postgres"
  engine_version    = "15.4"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "floci"
  username = "floci_admin"
  password = var.db_password # tfsec:ignore:AVD-AWS-0018 sensitive var; never plaintext in prod

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.security_group_id]
  availability_zone      = "us-east-1a"

  storage_encrypted   = true # SEC_INTENT: EBS encryption at rest (AVD-AWS-0077)
  publicly_accessible = false # SEC_INTENT: no direct internet access (AVD-AWS-0023)
  multi_az            = false # single AZ for sandbox

  backup_retention_period = 7 # SEC_INTENT: 7-day PITR (AVD-AWS-0114)
  skip_final_snapshot     = true # sandbox only; prod must be false

  # tfsec:ignore:AVD-AWS-0076 deletion_protection off in sandbox intentionally.
  deletion_protection = false

  tags = {
    Name        = "floci-postgres"
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# ElastiCache — Redis (single-node replication group)
# SEC_INTENT: transit and at-rest encryption both enabled (AVD-AWS-0050,
# AVD-AWS-0051). Single node (num_cache_clusters = 1) for sandbox.
# auth_token not set — floci does not enforce Redis AUTH. Prod should set it.
# -----------------------------------------------------------------------------
resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "floci-${var.environment}"
  description          = "floci Redis cache (single-node sandbox)"

  engine               = "redis"
  engine_version       = "7.0"
  node_type            = "cache.t3.micro"
  num_cache_clusters   = 1
  parameter_group_name = "default.redis7"
  port                 = 6379

  transit_encryption_enabled = true # SEC_INTENT: TLS in transit (AVD-AWS-0050)
  at_rest_encryption_enabled = true # SEC_INTENT: encryption at rest (AVD-AWS-0051)

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [var.security_group_id]

  automatic_failover_enabled = false # disabled for single-node

  tags = {
    Name        = "floci-redis"
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# MSK Cluster — Apache Kafka
# SEC_INTENT: TLS-only client broker communication (AVD-AWS-0073). In-cluster
# encryption enabled. Storage encrypted with SSE (no CMK in floci sandbox).
# tfsec:ignore:AVD-AWS-0074 floci sandbox uses SSE; prod sets encryption_at_rest_kms_key_arn.
# NOTE: MSK apply may require floci Pro ("kafka" service). tfsec scans fine.
# -----------------------------------------------------------------------------
resource "aws_msk_cluster" "main" {
  cluster_name           = "floci-kafka-${var.environment}"
  kafka_version          = "3.5.1"
  number_of_broker_nodes = 1

  broker_node_group_info {
    instance_type   = "kafka.t3.small"
    client_subnets  = [var.subnet_id]
    security_groups = [var.security_group_id]

    storage_info {
      ebs_storage_info {
        volume_size = 20
      }
    }
  }

  encryption_info {
    # SEC_INTENT: CMK at-rest encryption for MSK broker storage (AVD-AWS-0179).
    encryption_at_rest_kms_key_arn = var.kms_key_arn
    encryption_in_transit {
      client_broker = "TLS"  # SEC_INTENT: TLS-only, no plaintext (AVD-AWS-0073)
      in_cluster    = true
    }
  }

  tags = {
    Name        = "floci-kafka"
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# OpenSearch Domain
# SEC_INTENT: node-to-node and at-rest encryption enforced (AVD-AWS-0084,
# AVD-AWS-0085). HTTPS-only endpoint (TLS 1.2). Fine-grained access control
# enabled with no anonymous auth. Access policy scoped to VPC IPs.
# NOTE: OpenSearch apply may require floci Pro ("es" service). tfsec scans fine.
# -----------------------------------------------------------------------------
resource "aws_opensearch_domain" "main" {
  domain_name    = "floci-${var.environment}"
  engine_version = "OpenSearch_2.11"

  cluster_config {
    instance_type  = "t3.small.search"
    instance_count = 1
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 10
    volume_type = "gp3"
  }

  encrypt_at_rest {
    enabled = true # SEC_INTENT: SSE at rest (AVD-AWS-0085)
  }

  node_to_node_encryption {
    enabled = true # SEC_INTENT: in-cluster TLS (AVD-AWS-0084)
  }

  domain_endpoint_options {
    enforce_https       = true                          # SEC_INTENT: no HTTP
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07" # SEC_INTENT: TLS 1.2+
  }

  advanced_security_options {
    enabled                        = true
    anonymous_auth_enabled         = false # SEC_INTENT: no anonymous access (AVD-AWS-0122)
    internal_user_database_enabled = true
    master_user_options {
      master_user_name     = "admin"
      master_user_password = "Fl0ci@Sandbox!" # sandbox only — prod uses Secrets Manager
    }
  }

  # SEC_INTENT: access policy restricted to VPC CIDR — not open to 0.0.0.0/0.
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::000000000000:root" } # floci account ID
      Action    = "es:*"
      Resource  = "arn:aws:es:us-east-1:000000000000:domain/floci-${var.environment}/*"
    }]
  })

  vpc_options {
    subnet_ids         = [var.subnet_id]
    security_group_ids = [var.security_group_id]
  }

  tags = {
    Name        = "floci-opensearch"
    Environment = var.environment
  }
}
