# Two roles, two jobs:
#   execution role = what the ECS agent uses BEFORE your code runs
#                    (pull image, create log stream, fetch secrets)
#   task role      = what your application code gets from the credential
#                    provider while it runs (S3, SES, SQS ... whatever you grant)
# Mixing them up is the most common ECS IAM mistake; keep them separate.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Confused-deputy protection: only tasks in THIS account/region may assume.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

# ---------------------------------------------------------------------------
# Execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  description        = "ECS task execution role for ${var.name}: pull image, write logs, read secrets"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# AWS-managed: ecr:GetAuthorizationToken, ecr:BatchGetImage,
# ecr:GetDownloadUrlForLayer, ecr:BatchCheckLayerAvailability,
# logs:CreateLogStream, logs:PutLogEvents.
resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Secrets are read by the AGENT at task start, so the execution role (not the
# task role) needs GetSecretValue, scoped to exactly the secrets we inject.
data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.secret_arns) > 0 ? 1 : 0

  statement {
    sid       = "ReadInjectedSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == null ? [] : [var.kms_key_arn]
    content {
      sid       = "DecryptWithProjectKey"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count = length(var.secret_arns) > 0 ? 1 : 0

  name   = "read-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

# ---------------------------------------------------------------------------
# Task role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  description        = "ECS task role for ${var.name}: permissions of the application code"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ECS Exec tunnels through SSM Session Manager; these four actions are all it
# needs. Commands run as root inside the container, so prefer off in prod.
data "aws_iam_policy_document" "task_exec" {
  count = var.enable_execute_command ? 1 : 0

  statement {
    sid = "EcsExecSsmChannels"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_exec" {
  count = var.enable_execute_command ? 1 : 0

  name   = "ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_exec[0].json
}

# Application permissions supplied by the root (e.g. s3_media.task_policy_json).
resource "aws_iam_role_policy" "task_extra" {
  count = var.task_policy_json == null ? 0 : 1

  name   = "app"
  role   = aws_iam_role.task.id
  policy = var.task_policy_json
}
