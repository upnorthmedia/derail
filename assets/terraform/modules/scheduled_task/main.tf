# scheduled_task: Railway's "cron schedule" on AWS. EventBridge Scheduler calls
# ecs:RunTask on the web service's task definition with the command replaced,
# so the cron job runs in the same image, with the same env and secrets, in
# the same subnets and security group as the app. Nothing runs between
# invocations, so a nightly 2-minute job costs a few cents a month.
#
# Cost: Scheduler invocations are free up to 14M/month (then $1.00/M). The task
# itself is normal Fargate per-second billing (1-minute minimum) for however
# long the command runs, on Spot by default. Plus ~$0.005/h for the public IP
# while it runs.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # "arn:...:task-definition/acme-prod-web:7" -> "arn:...:task-definition/acme-prod-web:*"
  # so the role keeps working after every new revision without a policy change.
  task_definition_family_arn = replace(var.task_definition_arn, "/:\\d+$/", ":*")

  # Schedules live in the "default" group unless told otherwise.
  schedule_arn = "arn:aws:scheduler:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:schedule/default/${var.name}"
}

# ---------------------------------------------------------------------------
# IAM: what Scheduler is allowed to do on your behalf
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    # Confused-deputy protection: only THIS account's schedule may assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.schedule_arn]
    }
  }
}

data "aws_iam_policy_document" "scheduler" {
  # Start tasks from this family, only in this cluster.
  statement {
    sid       = "RunTask"
    actions   = ["ecs:RunTask"]
    resources = [local.task_definition_family_arn]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.cluster_arn]
    }
  }

  # RunTask tags the task (enable_ecs_managed_tags / propagate_tags), which
  # requires ecs:TagResource at creation time.
  statement {
    sid       = "TagTask"
    actions   = ["ecs:TagResource"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ecs:CreateAction"
      values   = ["RunTask"]
    }
  }

  # Hand the task definition's two roles to ECS, and only to ECS.
  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = [var.task_role_arn, var.execution_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name}-scheduler"
  description        = "EventBridge Scheduler role for ${var.name}: ecs:RunTask + iam:PassRole"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "run-task"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

# ---------------------------------------------------------------------------
# The schedule
# ---------------------------------------------------------------------------

resource "aws_scheduler_schedule" "this" {
  name        = var.name
  description = var.description
  state       = var.enabled ? "ENABLED" : "DISABLED"

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode                      = var.flexible_time_window_minutes > 0 ? "FLEXIBLE" : "OFF"
    maximum_window_in_minutes = var.flexible_time_window_minutes > 0 ? var.flexible_time_window_minutes : null
  }

  target {
    arn      = var.cluster_arn # for the ECS templated target the ARN is the cluster
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn     = var.task_definition_arn
      task_count              = 1
      group                   = var.name
      enable_ecs_managed_tags = true
      propagate_tags          = "TASK_DEFINITION"

      capacity_provider_strategy {
        capacity_provider = var.capacity_provider
        weight            = 1
        base              = 0
      }

      network_configuration {
        subnets          = var.subnet_ids
        security_groups  = var.security_group_ids
        assign_public_ip = var.assign_public_ip
      }
    }

    # The RunTask overrides. Same image, same env and secrets, different command.
    input = jsonencode({
      containerOverrides = [
        {
          name    = var.container_name
          command = var.command
        }
      ]
    })

    # Retries cover "could not start the task" (Spot capacity, throttling),
    # not a non-zero exit of your command.
    retry_policy {
      maximum_retry_attempts       = var.retry_attempts
      maximum_event_age_in_seconds = var.maximum_event_age_in_seconds
    }
  }
}
