output "schedule_arn" {
  description = "ARN of the EventBridge Scheduler schedule."
  value       = aws_scheduler_schedule.this.arn
}

output "schedule_name" {
  description = "Name of the schedule (aws scheduler get-schedule --name ...)."
  value       = aws_scheduler_schedule.this.name
}

output "scheduler_role_arn" {
  description = "ARN of the IAM role Scheduler assumes to call ecs:RunTask."
  value       = aws_iam_role.scheduler.arn
}
