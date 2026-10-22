variable "name" {
  type        = string
  description = "Name prefix, normally \"<project>-<environment>\". The SNS topic becomes \"<name>-alerts\" and the budget \"<name>-monthly\"."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "project" {
  type        = string
  description = "Value of the Project tag this budget and anomaly monitor filter on. Must be the same value the root puts in default_tags."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}$", var.project))
    error_message = "project must be 2-23 chars, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "alert_email" {
  type        = string
  description = "Address that receives budget emails directly and anomaly alerts via the SNS topic (confirm the subscription email)."

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must look like an email address."
  }
}

variable "monthly_budget_usd" {
  type        = number
  description = "Monthly cost budget for this project in USD. Alerts at 80% actual and 100% forecast."

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be a positive number."
  }
}

variable "anomaly_threshold_usd" {
  type        = number
  description = "Minimum total impact (USD) of a detected anomaly before an alert is sent. Lower = more sensitive = more noise."
  default     = 10

  validation {
    condition     = var.anomaly_threshold_usd >= 0
    error_message = "anomaly_threshold_usd must be zero or more."
  }
}

variable "create_anomaly_monitor" {
  type        = bool
  description = "Create a Cost Anomaly Detection monitor + subscription scoped to this project's tag. Free. Set false for throwaway dev environments to avoid clutter."
  default     = true
}
