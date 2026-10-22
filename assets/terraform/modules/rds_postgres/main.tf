# rds_postgres: a single RDS for PostgreSQL instance with the guardrails a small
# team forgets (encryption, backups, deletion protection, managed master secret,
# SSL enforced, alarms) and nothing that silently costs money (no Multi-AZ, no
# RDS Proxy, no Enhanced Monitoring unless you ask).
#
# Monthly cost with defaults (us-east-1, Oct 2026 list prices):
#   db.t4g.micro Single-AZ  ~$11.68   (x2 with multi_az = true)
#   20 GiB gp3 storage       ~$2.30   (x2 with multi_az = true)
#   RDS-managed secret       ~$0.40
#   Backups within 100% of allocated storage: free. Database Insights standard: free.

locals {
  identifier = "${var.name}-db"

  # "18" -> "postgres18", "17.6" -> "postgres17". Overridable for odd cases.
  parameter_group_family = coalesce(var.parameter_group_family, "postgres${split(".", var.engine_version)[0]}")

  # Burstable (db.t*) classes earn CPU credits; only they have a CPUCreditBalance metric.
  is_burstable = startswith(var.instance_class, "db.t")
}

# ---------------------------------------------------------------------------
# Network placement
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name        = "${var.name}-db"
  description = "Private subnets for ${local.identifier}"
  subnet_ids  = var.subnet_ids

  tags = { Name = "${var.name}-db" }
}

# The database answers only to the security groups you list. There is no CIDR
# rule and no egress rule: RDS never needs to open outbound connections.
resource "aws_security_group" "this" {
  name        = "${var.name}-db"
  description = "RDS ${local.identifier}: PostgreSQL from allowed app security groups only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-db" }

  lifecycle {
    create_before_destroy = true
  }
}

# count, not for_each: the SG IDs are created in the same apply (ECS task SGs)
# and are unknown at plan time. for_each over unknown values fails the very
# first plan with "Invalid for_each argument"; count only needs the list
# LENGTH, which is known. Downside: removing an entry from the middle of the
# list re-creates the rules after it (harmless, they are stateless rules).
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  count = length(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL from allowed security group ${count.index}"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = var.allowed_security_group_ids[count.index]
}

# ---------------------------------------------------------------------------
# Engine parameters
# ---------------------------------------------------------------------------

# A dedicated parameter group (instead of the shared default.postgresNN) so the
# app can add settings later without an instance replacement.
resource "aws_db_parameter_group" "this" {
  name        = "${var.name}-${local.parameter_group_family}"
  family      = local.parameter_group_family
  description = "Parameters for ${local.identifier}"

  # rds.force_ssl = 1 is already the default on PostgreSQL 15+, but stating it
  # makes the intent explicit and protects older engine versions: every client
  # must use TLS (use sslmode=verify-full with the RDS CA bundle).
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  dynamic "parameter" {
    for_each = var.extra_parameters
    content {
      name         = parameter.key
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  tags = { Name = "${var.name}-${local.parameter_group_family}" }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Log groups for exported engine logs
# ---------------------------------------------------------------------------

# RDS creates /aws/rds/instance/<id>/<type> itself with "never expire". Creating
# the group first lets us set retention and have it tagged for cost allocation.
# CloudWatch Logs: $0.50/GB ingested, $0.03/GB-month stored, 5 GB/month free.
resource "aws_cloudwatch_log_group" "exports" {
  for_each = toset(var.enabled_cloudwatch_logs_exports)

  name              = "/aws/rds/instance/${local.identifier}/${each.value}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

# ---------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier = local.identifier

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  # gp3 includes 3,000 IOPS / 125 MB/s at no extra charge up to 400 GiB. Never gp2/io1 here.
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name  = var.db_name
  username = var.master_username
  # RDS generates the master password, stores it in Secrets Manager
  # (name rds!db-...), rotates it every 7 days and the value NEVER enters
  # Terraform state. Read the ARN from output master_user_secret_arn.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = var.multi_az # cost: doubles instance + storage
  network_type           = "IPV4"

  # Current RSA CA, valid to 2061. rds-ca-2019 expired in Aug 2024.
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  backup_retention_period = var.backup_retention_period
  backup_window           = var.backup_window
  maintenance_window      = var.maintenance_window
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  apply_immediately          = var.apply_immediately

  # Two layers of delete protection: the API refuses while deletion_protection
  # is true, and if it is ever turned off a final snapshot is still taken.
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-db-final"

  # Database Insights standard mode = 7 days of DB load + top SQL, free on RDS
  # PostgreSQL for every class. "advanced" costs ~$0.0125/vCPU-hour.
  database_insights_mode                = var.enable_performance_insights ? "standard" : null
  performance_insights_enabled          = var.enable_performance_insights
  performance_insights_retention_period = var.enable_performance_insights ? 7 : null

  # Enhanced Monitoring (OS-level metrics) is deliberately off: it bills
  # CloudWatch Logs ingestion every few seconds. The CloudWatch metrics used by
  # the alarms below are free.
  monitoring_interval = 0

  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports

  tags = { Name = local.identifier }

  lifecycle {
    # Literal true on purpose: any plan that would destroy the database fails.
    # To really delete it, remove this block, set deletion_protection = false,
    # apply, then destroy (README has the procedure).
    prevent_destroy = true
    # Snapshot names must be unique in the account, so the value only matters
    # at teardown time. Ignoring drift here means a later rename never produces
    # a noisy "update in place" on a production database. When you really
    # tear down you delete this whole lifecycle block (README), and at that
    # point you also set a fresh, unique final_snapshot_identifier.
    ignore_changes = [final_snapshot_identifier]
  }

  depends_on = [aws_cloudwatch_log_group.exports]
}
