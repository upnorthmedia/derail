# Composition root for one project in one environment.
#
# Order of thought (and roughly of apply):
#   cluster -> alerts topic -> secrets -> ALB -> web service -> database and
#   cache (need the service SG) -> worker / cron (reuse the web image) -> media
#   -> CloudFront -> GitHub roles (need the service and repo ARNs).
# DNS and the cutover switch live in dns.tf, the one-off migration task
# definition in migrations.tf, the glue for a shared ALB / database in
# shared.tf. Everything is a plain resource or a local module.
#
# Agency mode: shared_cluster / shared_alb / shared_database swap the cluster,
# the ALB and the RDS instance for lookups of the platform/ root's shared ones
# (data.tf). The rest of this file reads local.cluster_*, local.https_listener_arn,
# local.alb_* and local.db_* and does not care which is in play.

# ---------------------------------------------------------------------------
# ECS cluster (one per project-environment unless shared; the cluster is free)
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  count = var.shared_cluster ? 0 : 1

  name = local.name

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }
}

# Both Fargate capacity providers are associated so services and scheduled
# tasks can choose FARGATE or FARGATE_SPOT per workload. (The platform root
# does the same for the shared cluster.)
resource "aws_ecs_cluster_capacity_providers" "this" {
  count = var.shared_cluster ? 0 : 1

  cluster_name       = aws_ecs_cluster.this[0].name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 0
  }
}

# ---------------------------------------------------------------------------
# Budget, anomaly detection and the SNS topic every alarm publishes to
# ---------------------------------------------------------------------------
module "budget_alerts" {
  source = "../../../modules/budget_alerts"

  name                   = local.name
  project                = var.project
  alert_email            = var.alert_email
  monthly_budget_usd     = var.monthly_budget_usd
  anomaly_threshold_usd  = 10
  create_anomaly_monitor = true
}

# ---------------------------------------------------------------------------
# Secrets: one JSON secret container; values are written by scripts/put_secrets.sh
# ---------------------------------------------------------------------------
module "secrets" {
  source = "../../../modules/secrets"

  name        = local.name
  secret_keys = var.secret_keys
}

# ---------------------------------------------------------------------------
# Load balancer + certificate (+ Route 53 record unless CloudFront owns the name)
# Skipped with shared_alb = true: shared.tf then attaches this project's
# certificate to the platform ALB and the records in dns.tf alias that ALB.
# ---------------------------------------------------------------------------
module "alb" {
  source = "../../../modules/alb_https"
  count  = var.shared_alb ? 0 : 1

  name              = local.name
  vpc_id            = data.aws_vpc.shared.id
  public_subnet_ids = data.aws_subnets.public.ids
  domain_name       = var.domain_name
  hosted_zone_id    = local.hosted_zone_id

  # Certificate SANs. With CloudFront in front the distribution connects to
  # origin.<domain>, which must be on the ALB certificate, and CloudFront owns
  # the public names (and the www redirect). Without CloudFront the ALB must
  # cover www itself (dns.tf adds the records and the redirect rule).
  additional_domain_names = local.alb_certificate_sans

  # The apex record is the cutover switch: only when the ALB is the public
  # entry point AND traffic_target = "aws" (dns.tf explains the sequence).
  create_dns_record          = !var.enable_cloudfront && local.dns_points_to_aws
  enable_deletion_protection = var.deletion_protection
}

# ---------------------------------------------------------------------------
# Web service (the HTTP container behind the ALB)
# ---------------------------------------------------------------------------
module "web" {
  source = "../../../modules/ecs_service"

  name         = "${local.name}-web"
  cluster_arn  = local.cluster_arn
  cluster_name = local.cluster_name
  vpc_id       = data.aws_vpc.shared.id
  subnet_ids   = local.task_subnet_ids

  assign_public_ip = local.assign_public_ip
  image_tag        = var.image_tag
  container_name   = local.container_name
  container_port   = var.container_port
  cpu              = var.cpu
  memory           = var.memory
  cpu_architecture = "ARM64" # Graviton: ~20% cheaper per vCPU-hour; the Dockerfile builds linux/arm64

  desired_count     = var.desired_count
  min_capacity      = var.min_capacity
  max_capacity      = var.max_capacity
  capacity_provider = var.capacity_provider

  environment = local.app_env
  secrets     = module.secrets.ecs_secrets
  secret_arns = [module.secrets.app_secret_arn]

  expose_http           = true
  https_listener_arn    = local.https_listener_arn
  alb_security_group_id = local.alb_security_group_id
  host_headers          = [var.domain_name] # CloudFront forwards the viewer Host unchanged; www is redirected before it gets here
  # Unique per project on a shared ALB (platform/README.md keeps the table);
  # the www redirect rule in dns.tf takes priority + 1.
  listener_rule_priority = var.listener_rule_priority
  health_check_path      = var.health_check_path

  enable_execute_command = var.enable_execute_command
  log_retention_days     = var.log_retention_days
  alarm_topic_arn        = module.budget_alerts.alerts_topic_arn
  task_policy_json       = var.enable_media_bucket ? module.media[0].task_policy_json : null
}

# ---------------------------------------------------------------------------
# Optional worker: same image, different command, no load balancer
# ---------------------------------------------------------------------------
module "worker" {
  source = "../../../modules/ecs_service"
  count  = var.enable_worker ? 1 : 0

  name         = "${local.name}-worker"
  cluster_arn  = local.cluster_arn
  cluster_name = local.cluster_name
  vpc_id       = data.aws_vpc.shared.id
  subnet_ids   = local.task_subnet_ids

  assign_public_ip = local.assign_public_ip
  # Reuse the web image: no second ECR repository, same build, different command.
  create_ecr_repository = false
  image                 = module.web.image
  container_name        = local.container_name
  container_port        = var.container_port
  cpu                   = local.worker_cpu    # null -> same as web
  memory                = local.worker_memory # null -> same as web
  cpu_architecture      = "ARM64"

  desired_count     = var.worker_desired_count
  min_capacity      = var.worker_min_capacity
  max_capacity      = var.worker_max_capacity
  capacity_provider = local.worker_capacity_provider

  environment       = local.app_env
  secrets           = module.secrets.ecs_secrets
  secret_arns       = [module.secrets.app_secret_arn]
  container_command = var.worker_command

  expose_http = false

  enable_execute_command = var.enable_execute_command
  log_retention_days     = var.log_retention_days
  alarm_topic_arn        = module.budget_alerts.alerts_topic_arn
  task_policy_json       = var.enable_media_bucket ? module.media[0].task_policy_json : null
}

# ---------------------------------------------------------------------------
# Database. Reachable only from the web/worker (and migration host) security
# groups on 5432. Skipped with shared_database = true: shared.tf then opens
# the platform instance's SG to the same security groups, and the project's
# database inside it is created out-of-band (README).
# ---------------------------------------------------------------------------
module "db" {
  source = "../../../modules/rds_postgres"
  count  = var.shared_database ? 0 : 1

  name       = local.name
  vpc_id     = data.aws_vpc.shared.id
  subnet_ids = data.aws_subnets.private.ids # tasks in public subnets still reach private subnets inside the VPC

  allowed_security_group_ids = local.data_client_security_group_ids

  engine_version      = var.db_engine_version
  instance_class      = var.db_instance_class
  allocated_storage   = var.db_allocated_storage
  multi_az            = var.db_multi_az
  deletion_protection = var.deletion_protection
  alarm_topic_arn     = module.budget_alerts.alerts_topic_arn
}

# ---------------------------------------------------------------------------
# Cache / queue broker (Railway Redis replacement). Same client list as RDS.
# ---------------------------------------------------------------------------
module "cache" {
  source = "../../../modules/valkey"
  count  = var.enable_cache ? 1 : 0

  name       = local.name
  vpc_id     = data.aws_vpc.shared.id
  subnet_ids = data.aws_subnets.private.ids

  allowed_security_group_ids = local.data_client_security_group_ids

  node_type        = var.cache_node_type
  maxmemory_policy = var.cache_maxmemory_policy
  alarm_topic_arn  = module.budget_alerts.alerts_topic_arn
}

# ---------------------------------------------------------------------------
# Cron jobs: EventBridge Scheduler -> RunTask on the web task definition with a
# command override. One schedule per entry in var.cron_jobs. Created PAUSED
# until crons_enabled = true (see the variable: no double runs before cutover).
# ---------------------------------------------------------------------------
module "cron" {
  source   = "../../../modules/scheduled_task"
  for_each = var.cron_jobs

  name                = "${local.name}-${each.key}"
  schedule_expression = each.value.schedule
  schedule_timezone   = "UTC"
  command             = each.value.command

  cluster_arn         = local.cluster_arn
  task_definition_arn = module.web.task_definition_arn
  task_role_arn       = module.web.task_role_arn
  execution_role_arn  = module.web.execution_role_arn
  container_name      = module.web.container_name

  subnet_ids         = local.task_subnet_ids
  security_group_ids = [module.web.security_group_id]
  assign_public_ip   = local.assign_public_ip
  # Spot is fine for retryable batch work and ~70% cheaper; set
  # cron_capacity_provider = "FARGATE" for jobs that must not be interrupted.
  capacity_provider = var.cron_capacity_provider

  enabled = var.crons_enabled
}

# ---------------------------------------------------------------------------
# Media bucket (+ CDN unless media_cdn = false): Vercel Blob / Railway volume
# replacement
# ---------------------------------------------------------------------------
module "media" {
  source = "../../../modules/s3_media"
  count  = var.enable_media_bucket ? 1 : 0

  name                 = local.name
  enable_cdn           = var.media_cdn
  domain_name          = var.media_cdn ? var.media_domain_name : null
  hosted_zone_id       = var.media_cdn && var.media_domain_name != null ? local.hosted_zone_id : null
  cors_allowed_origins = ["https://${var.domain_name}"]
}

# ---------------------------------------------------------------------------
# CloudFront in front of the ALB
# ---------------------------------------------------------------------------
module "cloudfront" {
  source = "../../../modules/cloudfront_app"
  count  = var.enable_cloudfront ? 1 : 0

  name                    = local.name
  domain_name             = var.domain_name
  additional_domain_names = var.additional_domain_names # SANs + aliases, 301 to domain_name at the edge
  hosted_zone_id          = local.hosted_zone_id
  origin_domain_name      = local.origin_domain_name

  origin_request_policy_name = var.cloudfront_origin_request_policy_name
  create_image_cache_policy  = var.create_image_cache_policy

  enable_waf       = var.enable_waf
  path_rate_limits = var.waf_path_rate_limits

  # The public alias records are the cutover switch (dns.tf).
  create_dns_records = local.dns_points_to_aws

  # The record and the certificate SAN must exist before CloudFront can reach the origin.
  depends_on = [aws_route53_record.origin]
}

# ---------------------------------------------------------------------------
# Temporary migration host (SSM-only EC2 inside the VPC) for pg_dump/pg_restore.
# enable_migration_host = true for the rehearsal/cutover window, false after.
# ---------------------------------------------------------------------------
module "migration_host" {
  source = "../../../modules/migration_host"
  count  = var.enable_migration_host ? 1 : 0

  name   = local.name
  vpc_id = data.aws_vpc.shared.id
  # Same placement logic as the tasks: public subnet + public IP when there is
  # no NAT gateway, private subnet otherwise.
  subnet_id        = local.task_subnet_ids[0]
  assign_public_ip = local.assign_public_ip

  instance_type = var.migration_host_instance_type
  pg_major      = local.migration_host_pg_major

  staging_bucket_arn = var.migration_host_staging_bucket_arn
  staging_prefix     = "migration/"

  # Build DATABASE_URL on the host without pasting passwords around. With a
  # shared database this is the platform master secret: the host is where
  # `pg_migrate.sh roles` / `restore` create the project's database and roles.
  readable_secret_arns = [local.db_master_secret_arn, module.secrets.app_secret_arn]

  port_forward_hosts = merge(
    { postgres = { host = local.db_address, port = local.db_port, local_port = 15432 } },
    var.enable_cache ? { valkey = { host = module.cache[0].primary_endpoint_address, port = module.cache[0].port, local_port = 16379 } } : {},
  )
}

# ---------------------------------------------------------------------------
# GitHub Actions roles (plan / apply / deploy) for this root only
# ---------------------------------------------------------------------------
module "github_roles" {
  source = "../../../modules/github_oidc_roles"

  name                  = local.name
  project               = var.project
  github_org            = var.github_org
  github_repo           = var.github_repo
  github_repository_ids = var.github_repository_ids
  github_environment    = var.github_environment
  apply_branch          = "main"
  oidc_provider_arn     = data.aws_iam_openid_connect_provider.github.arn

  state_bucket     = local.state_bucket
  state_key_prefix = local.state_key_prefix

  ecr_repository_arns = compact(concat(
    [module.web.ecr_repository_arn],
    var.enable_worker ? [module.worker[0].ecr_repository_arn] : [],
  ))
  # With shared_cluster this is the platform cluster: UpdateService stays
  # limited to the service ARNs below, RunTask to the tools family; only
  # ListTasks/DescribeTasks (read-only) then span other tenants' tasks.
  ecs_cluster_arn = local.cluster_arn
  ecs_service_arns = concat(
    [module.web.service_arn],
    var.enable_worker ? [module.worker[0].service_arn] : [],
  )
  pass_role_arns = concat(
    [module.web.task_role_arn, module.web.execution_role_arn],
    var.enable_worker ? [module.worker[0].task_role_arn, module.worker[0].execution_role_arn] : [],
  )

  # One-off migration runs (migrations.tf): RunTask on the tools family in this
  # cluster and read its output from the web log group.
  run_task_definition_family_arns = var.enable_migration_task ? [local.tools_family_arn] : []
  log_group_arns                  = [module.web.log_group_arn]
}
