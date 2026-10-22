output "app_secret_arn" {
  description = "ARN of the single JSON app secret. Grant the ECS execution role secretsmanager:GetSecretValue on it."
  value       = aws_secretsmanager_secret.app.arn
}

output "app_secret_name" {
  description = "Name of the app secret (\"<name>/app\"), the value scripts/put_secrets.sh needs."
  value       = aws_secretsmanager_secret.app.name
}

output "additional_secret_arns" {
  description = "Map of additional secret key => ARN."
  value       = { for k, s in aws_secretsmanager_secret.additional : k => s.arn }
}

output "secret_arns" {
  description = "Every secret ARN this module created (app + additional), ready for the ECS execution role's GetSecretValue policy (ecs_service input secret_arns)."
  value       = concat([aws_secretsmanager_secret.app.arn], [for s in aws_secretsmanager_secret.additional : s.arn])
}

output "ecs_secrets" {
  description = "List of { name, valueFrom } for the ECS container definition, one per key in secret_keys. valueFrom uses the \"<arn>:<KEY>::\" form that pulls one JSON key out of the app secret (the trailing \"::\" means latest version stage, no version id)."
  value = [
    for key in var.secret_keys : {
      name      = key
      valueFrom = "${aws_secretsmanager_secret.app.arn}:${key}::"
    }
  ]
}
