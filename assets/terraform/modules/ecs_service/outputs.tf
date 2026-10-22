output "service_name" {
  description = "Name of the ECS service."
  value       = aws_ecs_service.this.name
}

output "service_arn" {
  description = "ARN of the ECS service (for deploy-role IAM scoping)."
  value       = aws_ecs_service.this.id
}

output "task_definition_arn" {
  description = "ARN of the task definition revision Terraform registered (family:revision)."
  value       = aws_ecs_task_definition.this.arn
}

output "task_family" {
  description = "Task definition family name."
  value       = aws_ecs_task_definition.this.family
}

output "container_name" {
  description = "Name of the application container (for scheduled_task containerOverrides and ECS Exec)."
  value       = var.container_name
}

output "image" {
  description = "Full image reference the service runs. Pass to a worker service with create_ecr_repository = false."
  value       = local.image
}

output "ecr_repository_url" {
  description = "URL of the module-created ECR repository, or null when create_ecr_repository = false."
  value       = var.create_ecr_repository ? aws_ecr_repository.this[0].repository_url : null
}

output "ecr_repository_arn" {
  description = "ARN of the module-created ECR repository (for the GitHub deploy role), or null."
  value       = var.create_ecr_repository ? aws_ecr_repository.this[0].arn : null
}

output "security_group_id" {
  description = "Security group of the tasks. Allow it on 5432 in the database security group."
  value       = aws_security_group.this.id
}

output "task_role_arn" {
  description = "ARN of the task role (application permissions)."
  value       = aws_iam_role.task.arn
}

output "execution_role_arn" {
  description = "ARN of the task execution role (image pull, logs, secrets)."
  value       = aws_iam_role.execution.arn
}

output "log_group_name" {
  description = "CloudWatch Logs group receiving container stdout/stderr."
  value       = aws_cloudwatch_log_group.this.name
}

output "log_group_arn" {
  description = "ARN of the log group (for IAM policies that read task output, e.g. github_oidc_roles.log_group_arns)."
  value       = aws_cloudwatch_log_group.this.arn
}

output "target_group_arn" {
  description = "ARN of the ALB target group, or null when expose_http = false."
  value       = var.expose_http ? aws_lb_target_group.this[0].arn : null
}
