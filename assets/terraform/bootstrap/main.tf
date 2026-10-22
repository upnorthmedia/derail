# Bootstrap: the one root a human applies with admin credentials, once per
# AWS account. Everything else (network/, live/<project>/<env>/) stores its
# state in the bucket created here and is applied by CI through the OIDC
# provider created here. Nothing in this file costs money except the
# S3 storage for state files, which is pennies.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  name = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = var.repository
  }

  # Account id + region makes the bucket name globally unique without a
  # random suffix, so every root can predict it.
  state_bucket_name = "tfstate-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"

  cost_allocation_tag_keys = var.activate_cost_allocation_tags ? toset(keys(local.tags)) : toset([])
}

# -----------------------------------------------------------------------------
# Terraform state bucket
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name

  # Losing this bucket means losing the state of every root in the account.
  # prevent_destroy makes `terraform destroy` refuse to touch it; you would
  # have to delete this block first, on purpose.
  lifecycle {
    prevent_destroy = true
  }
}

# BucketOwnerEnforced disables ACLs entirely; everything is owned by the
# account and controlled by IAM + bucket policy, which is what we want.
resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Versioning is what lets you recover from a corrupted or accidentally
# overwritten state file: every write keeps the previous version.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 (AES256) is free. SSE-KMS costs ~$0.03 per 10k requests and
      # needs the key policy to allow every CI role; only worth it if you want
      # CloudTrail entries for every state read.
      sse_algorithm     = var.state_kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.state_kms_key_arn
    }
    # Bucket keys cut KMS request costs by ~99% when SSE-KMS is used; harmless otherwise.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # Must come after versioning is enabled, otherwise AWS rejects the
  # noncurrent-version rule.
  depends_on = [aws_s3_bucket_versioning.tfstate]

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    # Empty filter = applies to the whole bucket (the provider requires one of
    # filter/prefix to be present).
    filter {}

    # 90 days of state history is plenty for "undo last week's apply" and keeps
    # storage cost near zero. Current versions are never expired.
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # Half-uploaded state files from an interrupted apply are deleted after a week.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Refuse any request that is not over TLS. State can contain resource ids,
# endpoints and, if someone slips up, secrets; it must never cross the wire in
# the clear.
data "aws_iam_policy_document" "tfstate_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_tls_only.json

  # The public access block must exist before a policy is attached, otherwise
  # a racing apply can briefly have a bucket with a policy and no block.
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# -----------------------------------------------------------------------------
# GitHub Actions OIDC identity provider (account-wide, one per account)
# -----------------------------------------------------------------------------

# Lets GitHub Actions jobs assume IAM roles with short-lived credentials
# instead of long-lived access keys stored as repo secrets. The per-project
# roles that trust this provider are created by modules/github_oidc_roles.
#
# thumbprint_list is deliberately omitted: since July 2024 AWS validates the
# GitHub JWKS endpoint against its own trusted CA list and ignores any
# thumbprint for this provider, and the provider schema marks it
# optional/computed. If an older provider version ever demands it, the
# well-known value is "6938fd4d98bab03faadb97b34396831e3780aea1".
resource "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# -----------------------------------------------------------------------------
# Cost allocation tags (see the activate_cost_allocation_tags variable)
# -----------------------------------------------------------------------------

resource "aws_ce_cost_allocation_tag" "keys" {
  for_each = local.cost_allocation_tag_keys

  tag_key = each.key
  status  = "Active"
}

# -----------------------------------------------------------------------------
# Account-wide alerts: SNS topic + email
# -----------------------------------------------------------------------------

# One topic for account-level alarms (cost anomalies here; you can point
# CloudWatch alarms for shared resources at it too). Project roots get their
# own topic from modules/budget_alerts so a client's noise is separable.
resource "aws_sns_topic" "alerts" {
  name = var.alerts_topic_name
}

# SNS sends a confirmation email; nothing is delivered until the link in it is
# clicked. Terraform does not wait for the confirmation.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# AWS Budgets and Cost Anomaly Detection publish from their own service
# principals, so the topic policy must let them in. The SourceAccount
# condition stops another account's budgets from spamming this topic.
data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid     = "AccountOwnerFullAccess"
    effect  = "Allow"
    actions = ["sns:*"]
    resources = [
      aws_sns_topic.alerts.arn,
    ]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid     = "AllowCostServicesToPublish"
    effect  = "Allow"
    actions = ["sns:Publish"]
    resources = [
      aws_sns_topic.alerts.arn,
    ]

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
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

# -----------------------------------------------------------------------------
# Account-wide monthly budget (free)
# -----------------------------------------------------------------------------

# Budget notifications are free (only budget *actions* cost money). This is
# the "whole account" safety net; per-project budgets live in each root.
resource "aws_budgets_budget" "account_monthly" {
  name         = "${local.name}-account-monthly"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"

  # 80% of the budget actually spent: time to look.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # Forecast says the month will end over budget: time to act before it does.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# -----------------------------------------------------------------------------
# Cost Anomaly Detection (free) - per-service monitor for the whole account
# -----------------------------------------------------------------------------

# "DIMENSIONAL / SERVICE" is the monitor type AWS recommends as the baseline:
# it learns the normal spend of every service and flags unusual jumps (a
# runaway NAT bill, a forgotten instance). Needs ~10 days of history per
# service before it can detect anything, and lags Cost Explorer by up to 24h.
resource "aws_ce_anomaly_monitor" "services" {
  name              = "${local.name}-account-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

# IMMEDIATE delivery requires an SNS subscriber (DAILY/WEEKLY digests can go
# to email directly). The topic policy above grants costalerts.amazonaws.com
# publish rights, which is what makes this work.
resource "aws_ce_anomaly_subscription" "services" {
  name      = "${local.name}-account-anomalies"
  frequency = "IMMEDIATE"

  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.alerts.arn
  }

  # Only alert when the anomaly's total dollar impact is at least the
  # threshold; without this you get pinged for 40-cent blips.
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }

  depends_on = [aws_sns_topic_policy.alerts]
}
