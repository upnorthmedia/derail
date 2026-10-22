# valkey: one small ElastiCache for Valkey replication group, the drop-in for
# Railway's Redis service (job queues, sessions, caches). Valkey is the
# Redis-compatible fork AWS now defaults to; it is ~20% cheaper per node than
# the Redis OSS engine and runs the same protocol, so BullMQ / Celery / ioredis
# / redis-py connect unchanged.
#
# Shape decisions, in order of how often they bite people:
#   - Node-based, NOT ElastiCache Serverless, and cluster mode DISABLED. Queue
#     libraries (BullMQ, Celery/kombu, Sidekiq) use multi-key commands and Lua
#     scripts that assume one keyspace; on a cluster-mode endpoint they fail
#     with CROSSSLOT. Serverless is always cluster mode.
#   - TLS required (rediss://). The in-transit flag cannot be turned on later
#     without a new replication group, so it is on from day one.
#   - No AUTH token. aws_elasticache_replication_group.auth_token is stored in
#     Terraform state in clear text and the provider has no write-only variant
#     for it, which breaks the "no secret values in state" rule of this repo.
#     Inside a VPC the security group IS the authentication boundary: only the
#     listed task security groups can open 6379. If policy demands AUTH anyway,
#     set it out of band (aws elasticache modify-replication-group --auth-token
#     ... --auth-token-update-strategy SET) and add
#     lifecycle { ignore_changes = [auth_token] }; the README has the steps.
#
# Monthly cost (us-east-1, Oct 2026): cache.t4g.micro ~$11.68 per node;
# cache.t4g.small ~$23.36. Backups up to the node's memory are free. Data
# transfer inside one AZ is free; each replica in another AZ adds cross-AZ
# replication traffic ($0.01/GB each way).

locals {
  group_id = "${var.name}-cache"

  # "8.0" -> "valkey8", "7.2" -> "valkey7".
  parameter_group_family = "valkey${split(".", var.engine_version)[0]}"

  parameters = merge({ "maxmemory-policy" = var.maxmemory_policy }, var.extra_parameters)

  multi_node = var.num_cache_clusters > 1
}

# ---------------------------------------------------------------------------
# Network placement
# ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "this" {
  name        = local.group_id
  description = "Private subnets for ${local.group_id}"
  subnet_ids  = var.subnet_ids

  tags = { Name = local.group_id }
}

# The cache answers only to the security groups you list. No CIDR rule, no
# egress: ElastiCache never opens outbound connections.
resource "aws_security_group" "this" {
  name        = local.group_id
  description = "ElastiCache ${local.group_id}: 6379 from allowed security groups only"
  vpc_id      = var.vpc_id

  tags = { Name = local.group_id }

  lifecycle {
    create_before_destroy = true
  }
}

# count, not for_each: the task SG IDs are created in the same apply and are
# unknown at plan time (for_each would fail the first plan). See rds_postgres.
resource "aws_vpc_security_group_ingress_rule" "valkey" {
  count = length(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "Valkey from allowed security group ${count.index}"
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = var.allowed_security_group_ids[count.index]
}

# ---------------------------------------------------------------------------
# Engine parameters
# ---------------------------------------------------------------------------

# A dedicated group so maxmemory-policy (and BullMQ's notify-keyspace-events)
# can be set; the default.valkey8 group is read-only.
resource "aws_elasticache_parameter_group" "this" {
  name        = "${var.name}-${local.parameter_group_family}"
  family      = local.parameter_group_family
  description = "Parameters for ${local.group_id}"

  dynamic "parameter" {
    for_each = local.parameters
    content {
      name  = parameter.key
      value = parameter.value
    }
  }

  tags = { Name = "${var.name}-${local.parameter_group_family}" }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# The replication group (cluster mode disabled: one primary endpoint)
# ---------------------------------------------------------------------------

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = local.group_id
  description          = "Valkey for ${var.name} (queues, sessions, cache)"

  engine         = "valkey"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = 6379

  # num_cache_clusters (not num_node_groups) = cluster mode disabled. With 1
  # node there is nothing to fail over to; 2+ turns on automatic failover and
  # places the replica in another AZ.
  num_cache_clusters         = var.num_cache_clusters
  automatic_failover_enabled = local.multi_node
  multi_az_enabled           = local.multi_node

  parameter_group_name = aws_elasticache_parameter_group.this.name
  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.this.id]

  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn
  transit_encryption_enabled = true
  transit_encryption_mode    = "required" # clients MUST use rediss://

  snapshot_retention_limit = var.snapshot_retention_limit
  snapshot_window          = var.snapshot_retention_limit > 0 ? var.snapshot_window : null
  maintenance_window       = var.maintenance_window

  auto_minor_version_upgrade = true
  apply_immediately          = var.apply_immediately

  tags = { Name = local.group_id }
}

# ---------------------------------------------------------------------------
# Alarms (free ElastiCache metrics; created only when a topic is given)
# ---------------------------------------------------------------------------

locals {
  create_alarms = var.alarm_topic_arn != null
  alarm_actions = local.create_alarms ? [var.alarm_topic_arn] : []
  # Metrics are per node; the primary is always "<group id>-001".
  primary_cache_cluster_id = "${local.group_id}-001"
}

# Valkey is single-threaded for commands: EngineCPUUtilization is the honest
# number on 2-vCPU t4g nodes, not CPUUtilization (which caps near 50%).
resource "aws_cloudwatch_metric_alarm" "cpu" {
  count = local.create_alarms ? 1 : 0

  alarm_name          = "${local.group_id}-engine-cpu-high"
  alarm_description   = "ElastiCache ${local.group_id} engine CPU > 80% for 15 minutes"
  namespace           = "AWS/ElastiCache"
  metric_name         = "EngineCPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { CacheClusterId = local.primary_cache_cluster_id }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# With noeviction, 100% memory means the broker refuses writes (OOM errors in
# the app); with an LRU policy it means the hit rate is about to drop.
resource "aws_cloudwatch_metric_alarm" "memory" {
  count = local.create_alarms ? 1 : 0

  alarm_name          = "${local.group_id}-memory-high"
  alarm_description   = "ElastiCache ${local.group_id} memory > ${var.memory_alarm_threshold_percent}%"
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.memory_alarm_threshold_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { CacheClusterId = local.primary_cache_cluster_id }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Any eviction on a queue is data loss; on a cache it is a sizing signal.
resource "aws_cloudwatch_metric_alarm" "evictions" {
  count = local.create_alarms ? 1 : 0

  alarm_name          = "${local.group_id}-evictions"
  alarm_description   = "ElastiCache ${local.group_id} is evicting keys (memory too small for the working set)"
  namespace           = "AWS/ElastiCache"
  metric_name         = "Evictions"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { CacheClusterId = local.primary_cache_cluster_id }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
