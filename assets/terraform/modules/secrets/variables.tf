variable "name" {
  type        = string
  description = "Name prefix, normally \"<project>-<environment>\" from the root. The app secret is created as \"<name>/app\"."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "kms_key_arn" {
  type        = string
  description = "Optional customer-managed KMS key ARN to encrypt the secrets. null uses the AWS-managed key aws/secretsmanager, which is free; a CMK costs $1/month and lets you scope decrypt rights per project."
  default     = null
}

variable "recovery_window_in_days" {
  type        = number
  description = "Days a deleted secret can be restored before it is gone for good. 7-30, or 0 to delete immediately (only sensible for dev; a deleted-with-recovery secret blocks its name until the window ends)."
  default     = 30

  validation {
    condition     = var.recovery_window_in_days == 0 || (var.recovery_window_in_days >= 7 && var.recovery_window_in_days <= 30)
    error_message = "recovery_window_in_days must be 0 or between 7 and 30."
  }
}

variable "secret_keys" {
  type        = list(string)
  description = <<-EOT
    Environment variable names stored inside the app secret's JSON value, e.g.
    ["DATABASE_URL", "STRIPE_SECRET_KEY"]. Only the NAMES are known to Terraform; the values
    are written out-of-band by scripts/put_secrets.sh. The list is used to build the
    `secrets` entries for the ECS container definition (see output ecs_secrets).
  EOT
  default     = []

  validation {
    condition     = alltrue([for k in var.secret_keys : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k))])
    error_message = "secret_keys must be valid environment variable names (letters, digits, underscores, not starting with a digit)."
  }

  validation {
    condition     = length(var.secret_keys) == length(distinct(var.secret_keys))
    error_message = "secret_keys contains duplicates."
  }
}

variable "additional_secrets" {
  type        = map(string)
  description = "Extra stand-alone secret containers, as name => description. Each becomes \"<name>/<key>\". Use for things that rotate separately from the app env (e.g. a webhook signing key shared with another system). Default none."
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.additional_secrets) : can(regex("^[A-Za-z0-9_.-]{1,64}$", k))])
    error_message = "additional_secrets keys may contain letters, digits, '_', '.', '-' (max 64 chars)."
  }
}
