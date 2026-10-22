output "primary_endpoint_address" {
  description = "Hostname of the primary node (reads and writes). Clients must connect with TLS."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint_address" {
  description = "Hostname that load-balances reads across replicas. Identical to the primary when num_cache_clusters = 1."
  value       = aws_elasticache_replication_group.this.reader_endpoint_address
}

output "port" {
  description = "TCP port (6379)."
  value       = aws_elasticache_replication_group.this.port
}

output "redis_url" {
  description = "Connection URL with the TLS scheme, e.g. rediss://<host>:6379/0. Contains no credentials, so it is safe as a plain environment variable."
  value       = "rediss://${aws_elasticache_replication_group.this.primary_endpoint_address}:${aws_elasticache_replication_group.this.port}/0"
}

output "security_group_id" {
  description = "Security group attached to the cache (append more ingress rules for a bastion etc.)."
  value       = aws_security_group.this.id
}

output "replication_group_id" {
  description = "ElastiCache replication group id (for aws elasticache CLI commands)."
  value       = aws_elasticache_replication_group.this.id
}

output "replication_group_arn" {
  description = "ARN of the replication group (IAM policies, AWS Backup)."
  value       = aws_elasticache_replication_group.this.arn
}
