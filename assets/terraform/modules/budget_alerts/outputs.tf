output "alerts_topic_arn" {
  description = "ARN of this project's SNS alerts topic. Pass it as alarm_topic_arn to rds_postgres and ecs_service so their CloudWatch alarms land in the same inbox."
  value       = aws_sns_topic.alerts.arn
}

output "budget_name" {
  description = "Name of the monthly budget (visible in Billing > Budgets)."
  value       = aws_budgets_budget.monthly.name
}

output "anomaly_monitor_arn" {
  description = "ARN of the project's Cost Anomaly Detection monitor, or null when create_anomaly_monitor = false."
  value       = var.create_anomaly_monitor ? aws_ce_anomaly_monitor.project[0].arn : null
}
