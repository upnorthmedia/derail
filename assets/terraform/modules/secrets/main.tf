# Secret CONTAINERS only. Terraform creates the Secrets Manager entries and
# knows their ARNs; it never sees, stores or diffs the values. Values are
# written by scripts/put_secrets.sh (aws secretsmanager put-secret-value)
# and read by the ECS agent at task start. This keeps every secret out of
# Terraform state, plans, CI logs and PR comments.
#
# Cost: $0.40 per secret per month + $0.05 per 10k API calls. One app secret
# holding all env vars (instead of one secret per variable) is deliberate:
# it is cheaper, and ECS can pick individual JSON keys out of it with the
# "<arn>:<KEY>::" valueFrom syntax.

resource "aws_secretsmanager_secret" "app" {
  name        = "${var.name}/app"
  description = "Application environment variables for ${var.name} as one JSON object. Values managed outside Terraform."
  kms_key_id  = var.kms_key_arn

  # 0 deletes immediately; otherwise the secret is recoverable for N days and
  # its NAME stays reserved for that long (see README gotchas).
  recovery_window_in_days = var.recovery_window_in_days

  tags = {
    Name = "${var.name}/app"
  }
}

resource "aws_secretsmanager_secret" "additional" {
  for_each = var.additional_secrets

  name                    = "${var.name}/${each.key}"
  description             = each.value
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_in_days

  tags = {
    Name = "${var.name}/${each.key}"
  }
}
