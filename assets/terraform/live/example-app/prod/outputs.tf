# Everything the runbook, scripts/put_secrets.sh and the GitHub workflows read
# via `terraform output -json`.

output "app_url" {
  description = "Public URL of the application."
  value       = "https://${var.domain_name}"
}

output "image_tag" {
  description = "Image tag currently applied. terraform.yml reads it and passes -var image_tag=<this> so an infra-only apply never rolls the app back to the tfvars default."
  value       = var.image_tag
}

output "alb_dns_name" {
  description = "ALB hostname (useful for a curl --resolve smoke test before DNS cutover). The shared platform ALB when shared_alb = true."
  value       = local.alb_dns_name
}

output "cloudfront_domain_name" {
  description = "CloudFront hostname when enable_cloudfront = true, else null."
  value       = var.enable_cloudfront ? module.cloudfront[0].distribution_domain_name : null
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for invalidations, else null."
  value       = var.enable_cloudfront ? module.cloudfront[0].distribution_id : null
}

output "ecr_repository_url" {
  description = "ECR repository the deploy workflow pushes the web image to."
  value       = module.web.ecr_repository_url
}

output "worker_ecr_repository_url" {
  description = "ECR repository for the worker image (same Dockerfile), else null."
  value       = var.enable_worker ? module.worker[0].ecr_repository_url : null
}

output "ecs_cluster_name" {
  description = "ECS cluster name (the shared platform cluster when shared_cluster = true)."
  value       = local.cluster_name
}

output "ecs_service_name" {
  description = "Web ECS service name (aws ecs update-service --force-new-deployment after rotating secrets)."
  value       = module.web.service_name
}

output "worker_service_name" {
  description = "Worker ECS service name, else null."
  value       = var.enable_worker ? module.worker[0].service_name : null
}

output "task_family" {
  description = "Web task definition family (the one the service runs; one-off jobs use migration_task_family)."
  value       = module.web.task_family
}

output "log_group_name" {
  description = "CloudWatch Logs group for the web service (aws logs tail <name> --follow)."
  value       = module.web.log_group_name
}

output "db_endpoint" {
  description = "RDS hostname (the shared instance when shared_database = true). DATABASE_URL = postgresql://<user>:<password>@<endpoint>:<port>/<db>?sslmode=require"
  value       = local.db_address
}

output "db_port" {
  description = "RDS port."
  value       = local.db_port
}

output "db_name" {
  description = "Database name: created at launch on a dedicated instance; shared_db_name on a shared instance (created out-of-band with scripts/pg_migrate.sh)."
  value       = local.db_name
}

output "db_master_secret_arn" {
  description = "Secrets Manager secret holding the RDS-managed master password (the ARN is not secret; the value never enters state). With shared_database it is the PLATFORM master secret: use it to create the project's database and roles, never in the app."
  value       = local.db_master_secret_arn
}

output "app_secret_arn" {
  description = "ARN of the application secret container that scripts/put_secrets.sh fills."
  value       = module.secrets.app_secret_arn
}

output "app_secret_name" {
  description = "Name of the application secret (aws secretsmanager put-secret-value --secret-id <name>)."
  value       = module.secrets.app_secret_name
}

output "media_bucket_name" {
  description = "Media bucket name, else null."
  value       = var.enable_media_bucket ? module.media[0].bucket_name : null
}

output "media_url" {
  description = "Public base URL for media (CloudFront), null when the bucket is disabled or media_cdn = false."
  value       = var.enable_media_bucket ? module.media[0].media_url : null
}

output "alerts_topic_arn" {
  description = "SNS topic receiving alarms, budget and anomaly notifications."
  value       = module.budget_alerts.alerts_topic_arn
}

output "github_plan_role_arn" {
  description = "Role for `terraform plan` on pull requests (set as repo variable TF_PLAN_ROLE_ARN)."
  value       = module.github_roles.plan_role_arn
}

output "github_apply_role_arn" {
  description = "Role for `terraform apply` from main (repo variable TF_APPLY_ROLE_ARN)."
  value       = module.github_roles.apply_role_arn
}

output "github_deploy_role_arn" {
  description = "Role for pushing images and rolling the ECS service (repo variable DEPLOY_ROLE_ARN)."
  value       = module.github_roles.deploy_role_arn
}

# ---------------------------------------------------------------------------
# One-off migration task (migrations.tf). Names are a contract with
# .github/workflows/deploy.yml; do not rename.
# ---------------------------------------------------------------------------
output "migration_task_family" {
  description = "Task definition family of the tools task (RunTask on <family> uses its latest ACTIVE revision), or null when enable_migration_task = false."
  value       = var.enable_migration_task ? aws_ecs_task_definition.tools[0].family : null
}

output "migration_task_definition_arn" {
  description = "ARN (family:revision) of the tools task definition Terraform registered, or null."
  value       = var.enable_migration_task ? aws_ecs_task_definition.tools[0].arn : null
}

output "migration_run_task" {
  description = "Everything `aws ecs run-task` needs for a one-off migration: cluster, task definition family, network config (subnets, security groups, assign_public_ip ENABLED/DISABLED), container name and log group. null when enable_migration_task = false."
  value = var.enable_migration_task ? {
    cluster                = local.cluster_name
    task_definition_family = aws_ecs_task_definition.tools[0].family
    subnets                = local.task_subnet_ids
    security_groups        = [module.web.security_group_id]
    assign_public_ip       = local.assign_public_ip ? "ENABLED" : "DISABLED"
    container_name         = local.container_name
    log_group              = module.web.log_group_name
  } : null
}

# ---------------------------------------------------------------------------
# DNS cutover
# ---------------------------------------------------------------------------
output "hosted_zone_id" {
  description = "Route 53 hosted zone id in use (created or looked up)."
  value       = local.hosted_zone_id
}

output "hosted_zone_name_servers" {
  description = "Name servers to set at the registrar when create_hosted_zone = true (null otherwise: the existing zone is already delegated)."
  value       = var.create_hosted_zone ? aws_route53_zone.this[0].name_servers : null
}

output "traffic_target" {
  description = "Current position of the cutover switch (\"old\" or \"aws\")."
  value       = var.traffic_target
}

output "public_domain_names" {
  description = "Hostnames that point at AWS once traffic_target = \"aws\": domain_name first, then additional_domain_names (redirected to domain_name)."
  value       = concat([var.domain_name], var.additional_domain_names)
}

# ---------------------------------------------------------------------------
# Shared platform (for the runbook and the priority table in platform/README.md)
# ---------------------------------------------------------------------------
output "shared_cluster" {
  description = "true when the services run in the shared platform cluster."
  value       = var.shared_cluster
}

output "shared_alb" {
  description = "true when this project rides the shared platform ALB (own certificate via SNI + host-header rules)."
  value       = var.shared_alb
}

output "shared_database" {
  description = "true when the database lives inside the shared platform RDS instance."
  value       = var.shared_database
}

output "listener_rule_priority" {
  description = "Priority of this project's web rule on the HTTPS listener (the redirect rule uses + 1). Record it in platform/README.md when shared_alb = true."
  value       = var.listener_rule_priority
}

output "shared_alb_certificate_arn" {
  description = "ARN of this project's certificate attached to the shared listener (SNI), or null when shared_alb = false."
  value       = var.shared_alb ? aws_acm_certificate_validation.shared_alb[0].certificate_arn : null
}

# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------
output "redis_url" {
  description = "rediss://<host>:6379/0 of the Valkey replication group (no credentials; also injected as REDIS_URL), or null when enable_cache = false."
  value       = var.enable_cache ? module.cache[0].redis_url : null
}

output "cache_endpoint" {
  description = "Valkey primary endpoint hostname, or null."
  value       = var.enable_cache ? module.cache[0].primary_endpoint_address : null
}

# ---------------------------------------------------------------------------
# Migration host (only while enable_migration_host = true)
# ---------------------------------------------------------------------------
output "migration_host_instance_id" {
  description = "EC2 instance id of the migration host, or null."
  value       = var.enable_migration_host ? module.migration_host[0].instance_id : null
}

output "migration_host_session_command" {
  description = "`aws ssm start-session` command for an interactive shell on the migration host, or null."
  value       = var.enable_migration_host ? module.migration_host[0].session_command : null
}

output "migration_host_port_forward_commands" {
  description = "Port-forward commands (postgres -> localhost:15432, valkey -> localhost:16379) through the migration host, or null."
  value       = var.enable_migration_host ? module.migration_host[0].port_forward_commands : null
}
