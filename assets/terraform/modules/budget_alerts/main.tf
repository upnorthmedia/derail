# Per-project cost guardrails. Everything in here is free: AWS Budgets
# notifications, Cost Anomaly Detection and SNS email (first 1,000/month)
# have no charge. The only thing that costs money is ignoring the emails.
#
# How "per project" works: the root tags every resource Project=<project>
# via default_tags, bootstrap activated Project as a cost-allocation tag, and
# the budget and anomaly monitor below filter on that tag.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# -----------------------------------------------------------------------------
# SNS topic + email subscription
# -----------------------------------------------------------------------------

# One topic per project so a client's alarms (this, plus the RDS/ECS
# CloudWatch alarms the other modules create) can be routed separately.
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"

  tags = {
    Name = "${var.name}-alerts"
  }
}

# SNS emails a confirmation link; nothing arrives until it is clicked.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Budgets and Anomaly Detection publish from service principals, so the topic
# policy must allow them (otherwise the subscription silently never fires).
# aws:SourceAccount stops another account's budgets using this topic.
data "aws_iam_policy_document" "topic" {
  statement {
    sid       = "AccountOwnerFullAccess"
    effect    = "Allow"
    actions   = ["sns:*"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowCostServicesToPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type = "Service"
      identifiers = [
        "budgets.amazonaws.com",
        "costalerts.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # CloudWatch alarms (from rds_postgres / ecs_service) publish as the
  # account, which the first statement already covers.
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.topic.json
}

# -----------------------------------------------------------------------------
# Monthly budget filtered on the Project tag
# -----------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"

  # TagKeyValue values take the form "user:<Key>$<Value>". The "$" is a
  # literal; format() avoids HCL reading "${" as an interpolation.
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", var.project)]
  }

  # 80% actually spent: look at Cost Explorer grouped by service.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # Forecast for the month exceeds the budget: act before it does.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }

  tags = {
    Name = "${var.name}-monthly"
  }
}

# -----------------------------------------------------------------------------
# Cost Anomaly Detection on the Project tag
# -----------------------------------------------------------------------------

# CUSTOM monitors take the Cost Explorer "Expression" JSON. This one matches
# everything tagged Project=<project>. The bootstrap root has the per-service
# account-wide monitor; this one tells you WHICH project spiked.
resource "aws_ce_anomaly_monitor" "project" {
  count = var.create_anomaly_monitor ? 1 : 0

  name         = "${var.name}-anomalies"
  monitor_type = "CUSTOM"

  monitor_specification = jsonencode({
    Tags = {
      Key          = "Project"
      Values       = [var.project]
      MatchOptions = ["EQUALS"]
    }
  })

  tags = {
    Name = "${var.name}-anomalies"
  }
}

# IMMEDIATE needs an SNS subscriber (email subscribers only get DAILY/WEEKLY
# digests). Alerts fire only when the anomaly's total impact is at least
# anomaly_threshold_usd, so 50-cent blips do not page anyone.
resource "aws_ce_anomaly_subscription" "project" {
  count = var.create_anomaly_monitor ? 1 : 0

  name             = "${var.name}-anomalies"
  frequency        = "IMMEDIATE"
  monitor_arn_list = [aws_ce_anomaly_monitor.project[0].arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }

  tags = {
    Name = "${var.name}-anomalies"
  }

  # AWS validates that costalerts may publish to the topic at create time.
  depends_on = [aws_sns_topic_policy.alerts]
}
