# Project roots discover everything by name/tag; these outputs are for humans,
# the console and the runbook.

output "cluster_name" {
  description = "Shared ECS cluster name (= platform_name). Project roots use it with shared_cluster = true."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "Shared ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "alb_arn" {
  description = "Shared ALB ARN, or null when create_shared_alb = false."
  value       = var.create_shared_alb ? module.alb[0].alb_arn : null
}

output "alb_dns_name" {
  description = "Shared ALB hostname (curl --resolve smoke tests; alias target for every tenant), or null."
  value       = var.create_shared_alb ? module.alb[0].alb_dns_name : null
}

output "alb_zone_id" {
  description = "Route 53 zone id of the shared ALB for alias records, or null."
  value       = var.create_shared_alb ? module.alb[0].alb_zone_id : null
}

output "alb_https_listener_arn" {
  description = "ARN of the shared :443 listener that tenants attach certificates and rules to, or null."
  value       = var.create_shared_alb ? module.alb[0].https_listener_arn : null
}

output "alb_security_group_id" {
  description = "Security group of the shared ALB; tenant task SGs accept their container port from it only. Null when create_shared_alb = false."
  value       = var.create_shared_alb ? module.alb[0].security_group_id : null
}

output "platform_url" {
  description = "https://<platform_domain_name>: answers 404 \"no rule matched\" by design, which is the health check for the ALB itself."
  value       = var.create_shared_alb ? "https://${var.platform_domain_name}" : null
}

output "db_identifier" {
  description = "Shared RDS instance identifier (\"<platform_name>-db\"); project roots look it up with shared_database = true. Null when create_shared_database = false."
  value       = var.create_shared_database ? module.db[0].instance_identifier : null
}

output "db_address" {
  description = "Shared RDS hostname, or null."
  value       = var.create_shared_database ? module.db[0].address : null
}

output "db_port" {
  description = "Shared RDS port, or null."
  value       = var.create_shared_database ? module.db[0].port : null
}

output "db_security_group_id" {
  description = "Security group of the shared instance (tenant roots add their ingress rules to it), or null."
  value       = var.create_shared_database ? module.db[0].security_group_id : null
}

output "db_master_user_secret_arn" {
  description = "RDS-managed master secret of the shared instance. Used ONLY to create each project's database and roles (scripts/pg_migrate.sh roles); applications never use the master user. Null when create_shared_database = false."
  value       = var.create_shared_database ? module.db[0].master_user_secret_arn : null
}

output "alerts_topic_arn" {
  description = "SNS topic receiving the shared pool's RDS alarms, budget and anomaly notifications."
  value       = module.budget_alerts.alerts_topic_arn
}
