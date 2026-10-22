variable "aws_region" {
  type        = string
  description = "Region for the state bucket and SNS topic. Budgets, Cost Explorer and IAM are global, so this only affects where the bucket and topic live."
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Slug used for the Project tag on bootstrap resources and as the prefix of resource names. Keep the default unless you run several platforms in one account."
  default     = "platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}$", var.project))
    error_message = "project must be 2-23 chars, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "environment" {
  type        = string
  description = "Environment tag for bootstrap resources. Account-wide plumbing is normally tagged prod."
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "repository" {
  type        = string
  description = "Git repository that holds this Terraform code, e.g. github.com/acme/infra. Used for the Repository tag so anyone looking at a resource can find its source."
}

variable "alert_email" {
  type        = string
  description = "Email address that receives budget and cost-anomaly alerts. You must click the confirmation link SNS sends to this address."

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must look like an email address."
  }
}

variable "alerts_topic_name" {
  type        = string
  description = "Name of the account-wide SNS topic that receives cost-anomaly alerts. Project roots create their own topics; this one is for account-level noise."
  default     = "platform-alerts"
}

variable "monthly_budget_usd" {
  type        = number
  description = "Account-wide monthly cost budget in USD. You get an email at 80% actual spend and when the forecast crosses 100%. Set this a little above what you expect the whole account to cost."

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be a positive number."
  }
}

variable "anomaly_threshold_usd" {
  type        = number
  description = "Cost Anomaly Detection only alerts when the anomaly's total impact is at least this many USD. 10 is a sensible floor for a small account; lower values get noisy."
  default     = 10

  validation {
    condition     = var.anomaly_threshold_usd >= 0
    error_message = "anomaly_threshold_usd must be zero or more."
  }
}

variable "state_kms_key_arn" {
  type        = string
  description = "Optional KMS key ARN for encrypting the state bucket with SSE-KMS. Leave null for SSE-S3 (AES256), which is free and fine for most teams. SSE-KMS adds a small per-request charge and CloudTrail decrypt logs."
  default     = null
}

variable "enable_github_oidc" {
  type        = bool
  description = "Create the GitHub Actions OIDC identity provider. An account can hold only ONE provider for token.actions.githubusercontent.com; set this to false if one already exists (and import or reference it instead)."
  default     = true
}

variable "activate_cost_allocation_tags" {
  type        = bool
  description = <<-EOT
    Activate Project/Environment/ManagedBy/Repository as cost-allocation tags.
    AWS only lists a tag key for activation up to 24 hours AFTER it was first used on a
    resource, and the provider fails if the key is not listed yet. So: apply once with this
    false (the default), wait a day, set it to true and apply again. Costs are only
    attributed from activation onwards, so do not forget the second apply.
  EOT
  default     = false
}
