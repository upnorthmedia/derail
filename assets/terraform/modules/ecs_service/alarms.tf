# CloudWatch alarms on free ECS/ALB metrics. First 10 alarms per account are
# free, then $0.10 per alarm-month. Created only when alarm_topic_arn is set.

locals {
  create_alarms     = var.alarm_topic_arn != null
  create_alb_alarms = local.create_alarms && var.expose_http
  alarm_actions     = local.create_alarms ? [var.alarm_topic_arn] : []
}

# The app is answering with 5xx. Also the alarm ECS watches for rollback when
# deployment_alarm_rollback = true.
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  count = local.create_alb_alarms ? 1 : 0

  alarm_name          = "${var.name}-target-5xx"
  alarm_description   = "${var.name}: >= 5 HTTP 5xx responses from the app in two consecutive 5-minute periods"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching" # no traffic is not an error
  dimensions = {
    LoadBalancer = local.alb_arn_suffix
    TargetGroup  = aws_lb_target_group.this[0].arn_suffix
  }
  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

# A task is failing its health check; with desired_count = 1 this is an outage.
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  count = local.create_alb_alarms ? 1 : 0

  alarm_name          = "${var.name}-unhealthy-hosts"
  alarm_description   = "${var.name}: at least one target is unhealthy for 2 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = local.alb_arn_suffix
    TargetGroup  = aws_lb_target_group.this[0].arn_suffix
  }
  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

# Sustained CPU above the autoscaling target means scaling is capped
# (max_capacity) or the app is spinning.
resource "aws_cloudwatch_metric_alarm" "cpu" {
  count = local.create_alarms ? 1 : 0

  alarm_name          = "${var.name}-cpu-high"
  alarm_description   = "${var.name}: average CPU > 85% for 15 minutes"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = aws_ecs_service.this.name
  }
  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

# Memory climbing toward the task limit is the precursor to an OOM kill
# (which shows up as a task that "just restarted" with exit code 137).
resource "aws_cloudwatch_metric_alarm" "memory" {
  count = local.create_alarms ? 1 : 0

  alarm_name          = "${var.name}-memory-high"
  alarm_description   = "${var.name}: average memory > 85% for 15 minutes"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = aws_ecs_service.this.name
  }
  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}
