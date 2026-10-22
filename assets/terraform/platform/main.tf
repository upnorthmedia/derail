# Shared platform: the fixed-cost pieces several small projects in one account
# can share so each project's marginal cost gets close to Railway's.
#
#   ECS cluster "<platform_name>"        free; sharing only reduces console noise
#   ALB "<platform_name>-alb"            ~$25/month, shared by N projects (host-header rules + SNI certs)
#   RDS "<platform_name>-db"             ~$26/month for db.t4g.small + 20 GiB, one database per project inside
#   SNS/budget/anomaly for the pool      free
#
# Applied ONCE per account by a human, after network/ and before any
# live/<project>/<env> root that sets shared_cluster / shared_alb /
# shared_database. Project roots never read this state: they find the cluster
# by name, the ALB by tags (Name = "<platform_name>-alb", Shared = "true") and
# the database by identifier ("<platform_name>-db") + the SG tag Name.
#
# What is deliberately NOT here: secrets, task roles, log groups, buckets, ECR
# repositories. Those stay per project so one project's destroy, IAM policy or
# log retention never touches another's.

locals {
  name = "${var.platform_name}-${var.environment}"

  # Project = <platform_name> puts the whole shared pool on its own Cost
  # Explorer line. The README explains how to split it across projects.
  tags = {
    Project     = var.platform_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = var.repository
  }
}

# ---------------------------------------------------------------------------
# Shared ECS cluster. Named exactly <platform_name> so project roots can use
# data "aws_ecs_cluster" { cluster_name = var.platform_name }.
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = var.platform_name

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }

  tags = { Name = var.platform_name }
}

# Both Fargate capacity providers so tenants can pick FARGATE or FARGATE_SPOT
# per service without touching this root.
resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 0
  }
}

# ---------------------------------------------------------------------------
# Alerts topic, budget and anomaly monitor for the shared pool. The name is
# "<platform_name>-<environment>" (topic "platform-prod-alerts") so it does not
# collide with bootstrap's account-wide "platform-alerts" topic.
# ---------------------------------------------------------------------------
module "budget_alerts" {
  source = "../modules/budget_alerts"

  name                   = local.name
  project                = var.platform_name
  alert_email            = var.alert_email
  monthly_budget_usd     = var.monthly_budget_usd
  anomaly_threshold_usd  = 10
  create_anomaly_monitor = true
}

# ---------------------------------------------------------------------------
# Shared ALB. The platform owns one hostname (the listener's default
# certificate, answering 404). Each project attaches its own certificate via
# aws_lb_listener_certificate and its own host-header rule.
# ---------------------------------------------------------------------------
module "alb" {
  source = "../modules/alb_https"
  count  = var.create_shared_alb ? 1 : 0

  name              = var.platform_name
  vpc_id            = data.aws_vpc.shared.id
  public_subnet_ids = data.aws_subnets.public.ids
  domain_name       = var.platform_domain_name
  hosted_zone_id    = data.aws_route53_zone.platform[0].zone_id
  create_dns_record = true
  idle_timeout      = var.alb_idle_timeout

  # Deleting a shared ALB takes every tenant offline at once.
  enable_deletion_protection = var.deletion_protection

  # Discovery tags for project roots (data "aws_lb" matches on tags).
  tags = { Shared = "true" }
}

# ---------------------------------------------------------------------------
# Shared RDS instance. No ingress rules here: each project root adds
# aws_vpc_security_group_ingress_rule resources on this SG from its own task
# security groups, so removing a project removes exactly its rules.
# ---------------------------------------------------------------------------
module "db" {
  source = "../modules/rds_postgres"
  count  = var.create_shared_database ? 1 : 0

  name       = var.platform_name
  vpc_id     = data.aws_vpc.shared.id
  subnet_ids = data.aws_subnets.private.ids

  allowed_security_group_ids = []

  engine_version          = var.db_engine_version
  instance_class          = var.db_instance_class
  allocated_storage       = var.db_allocated_storage
  max_allocated_storage   = var.db_max_allocated_storage
  multi_az                = var.db_multi_az # cost: doubles the instance for every tenant's benefit
  backup_retention_period = var.db_backup_retention_period
  deletion_protection     = var.deletion_protection

  # The initial database is a placeholder; every project gets its own database
  # and roles via scripts/pg_migrate.sh (roles / restore --target-db).
  db_name = "platform"

  connection_alarm_threshold = var.db_connection_alarm_threshold
  alarm_topic_arn            = module.budget_alerts.alerts_topic_arn
}
