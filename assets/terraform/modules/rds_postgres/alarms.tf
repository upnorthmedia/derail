# CloudWatch alarms. All RDS metrics used here are free; the first 10 alarms in
# an account are free, then $0.10 per alarm-month. Created only when an SNS
# topic is supplied so dev stacks can opt out.

locals {
  create_alarms = var.alarm_topic_arn != null
  alarm_actions = local.create_alarms ? [var.alarm_topic_arn] : []
}

# Sustained CPU usually means a missing index or an N+1 query, not a need for
# a bigger instance. 15 minutes avoids paging on a nightly batch job.
resource "aws_cloudwatch_metric_alarm" "cpu" {
  count = local.create_alarms ? 1 : 0

  alarm_name          = "${local.identifier}-cpu-high"
  alarm_description   = "RDS ${local.identifier} CPU > 80% for 15 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# A full disk puts Postgres into read-only mode; storage autoscaling
# (max_allocated_storage) is the fix, this alarm is the backstop.
resource "aws_cloudwatch_metric_alarm" "free_storage" {
  count = local.create_alarms ? 1 : 0

  alarm_name          = "${local.identifier}-free-storage-low"
  alarm_description   = "RDS ${local.identifier} free storage < 2 GiB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2 * 1024 * 1024 * 1024 # bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Too many connections on a 1 GiB instance = "FATAL: remaining connection
# slots are reserved". Fix in the app (pool size) or with PgBouncer, not with
# RDS Proxy ($22/mo minimum).
resource "aws_cloudwatch_metric_alarm" "connections" {
  count = local.create_alarms ? 1 : 0

  alarm_name          = "${local.identifier}-connections-high"
  alarm_description   = "RDS ${local.identifier} connections > ${var.connection_alarm_threshold}"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.connection_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Burstable classes only. RDS t-classes are always "unlimited", so an empty
# credit balance does not throttle you: it bills $0.075 per vCPU-hour instead.
resource "aws_cloudwatch_metric_alarm" "cpu_credits" {
  count = local.create_alarms && local.is_burstable ? 1 : 0

  alarm_name          = "${local.identifier}-cpu-credits-low"
  alarm_description   = "RDS ${local.identifier} CPU credit balance < 20 (surplus credits are being billed)"
  namespace           = "AWS/RDS"
  metric_name         = "CPUCreditBalance"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 20
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Low freeable memory precedes swapping and connection failures on micro/small.
resource "aws_cloudwatch_metric_alarm" "freeable_memory" {
  count = local.create_alarms ? 1 : 0

  alarm_name          = "${local.identifier}-freeable-memory-low"
  alarm_description   = "RDS ${local.identifier} freeable memory < 100 MiB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 100 * 1024 * 1024 # bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
