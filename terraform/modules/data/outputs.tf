output "db_endpoint" {
  description = "RDS PostgreSQL endpoint address."
  value       = aws_db_instance.main.endpoint
}

output "db_identifier" {
  description = "RDS instance identifier."
  value       = aws_db_instance.main.identifier
}

output "cache_primary_endpoint" {
  description = "ElastiCache Redis primary endpoint."
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "msk_bootstrap_brokers" {
  description = "MSK Kafka TLS bootstrap broker string."
  value       = aws_msk_cluster.main.bootstrap_brokers_tls
}

output "msk_cluster_arn" {
  description = "ARN of the MSK cluster."
  value       = aws_msk_cluster.main.arn
}

output "opensearch_endpoint" {
  description = "OpenSearch domain endpoint."
  value       = aws_opensearch_domain.main.endpoint
}

output "opensearch_domain_arn" {
  description = "ARN of the OpenSearch domain."
  value       = aws_opensearch_domain.main.arn
}
