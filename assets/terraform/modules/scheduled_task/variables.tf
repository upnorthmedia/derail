variable "name" {
  description = "Schedule name, e.g. \"acme-prod-cleanup\". Also names the scheduler IAM role and the ECS task group."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,50}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, start with a letter, and be 2-51 characters."
  }
}

variable "schedule_expression" {
  description = "EventBridge Scheduler expression: \"rate(1 hour)\", \"cron(0 5 * * ? *)\" (SIX fields: minutes hours day-of-month month day-of-week year; use ? for one of day-of-month/day-of-week) or \"at(2026-12-31T23:59:00)\"."
  type        = string

  validation {
    condition     = can(regex("^(rate\\([0-9]+ (minute|minutes|hour|hours|day|days)\\)|cron\\([^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+\\)|at\\([0-9T:-]+\\))$", var.schedule_expression))
    error_message = "schedule_expression must be rate(N unit), a 6-field cron(...) or at(yyyy-mm-ddThh:mm:ss). Note: Scheduler cron has 6 fields, not the 5 of Unix cron."
  }
}

variable "schedule_timezone" {
  description = "IANA time zone the cron expression is evaluated in, e.g. \"America/Chicago\". Daylight-saving shifts are handled for you."
  type        = string
  default     = "UTC"
}

variable "cluster_arn" {
  description = "ECS cluster ARN the task runs in (the schedule target)."
  type        = string
}

variable "task_definition_arn" {
  description = "Task definition ARN to run (ecs_service output task_definition_arn). The web service's task definition is reused; only the command differs."
  type        = string
}

variable "task_role_arn" {
  description = "Task role ARN of that task definition (scheduler needs iam:PassRole on it)."
  type        = string
}

variable "execution_role_arn" {
  description = "Execution role ARN of that task definition (scheduler needs iam:PassRole on it)."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the one-off task. Use the same subnets as the service."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1 && length(var.subnet_ids) <= 16
    error_message = "Provide between 1 and 16 subnets."
  }
}

variable "security_group_ids" {
  description = "Security groups for the task. Reuse the service's SG so the database already trusts it."
  type        = list(string)

  validation {
    condition     = length(var.security_group_ids) >= 1 && length(var.security_group_ids) <= 5
    error_message = "Provide between 1 and 5 security groups."
  }
}

variable "assign_public_ip" {
  description = "Public IPv4 for the task ENI (needed in public subnets without NAT to pull the image). Billed ~$0.005/hour only while the task runs."
  type        = bool
  default     = true
}

variable "container_name" {
  description = "Name of the container in the task definition whose command is overridden (ecs_service output container_name)."
  type        = string
}

variable "command" {
  description = "Command to run instead of the image CMD, as an argv list, e.g. [\"node\", \"scripts/cleanup.js\"] or [\"npx\", \"prisma\", \"migrate\", \"deploy\"]."
  type        = list(string)

  validation {
    condition     = length(var.command) >= 1
    error_message = "command must have at least one element."
  }
}

variable "capacity_provider" {
  description = "FARGATE_SPOT (default: up to 70% cheaper; a short job that can simply run again next time is the ideal Spot workload) or FARGATE when the job must not be interrupted. There is no automatic fallback between the two."
  type        = string
  default     = "FARGATE_SPOT"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT"], var.capacity_provider)
    error_message = "capacity_provider must be FARGATE or FARGATE_SPOT."
  }
}

variable "flexible_time_window_minutes" {
  description = "0 = run exactly on schedule. N = run at any point within N minutes after the scheduled time (1-1440), which smooths load when many schedules share a time."
  type        = number
  default     = 0

  validation {
    condition     = var.flexible_time_window_minutes >= 0 && var.flexible_time_window_minutes <= 1440
    error_message = "flexible_time_window_minutes must be between 0 and 1440."
  }
}

variable "retry_attempts" {
  description = "How many times Scheduler retries the RunTask API call if ECS cannot start the task (e.g. no Spot capacity, throttling). This does NOT re-run a task whose command exited non-zero."
  type        = number
  default     = 1

  validation {
    condition     = var.retry_attempts >= 0 && var.retry_attempts <= 185
    error_message = "retry_attempts must be between 0 and 185."
  }
}

variable "maximum_event_age_in_seconds" {
  description = "Give up retrying RunTask after this many seconds (60-86400). Keep it shorter than the schedule interval so a stuck invocation cannot pile onto the next one."
  type        = number
  default     = 3600

  validation {
    condition     = var.maximum_event_age_in_seconds >= 60 && var.maximum_event_age_in_seconds <= 86400
    error_message = "maximum_event_age_in_seconds must be between 60 and 86400."
  }
}

variable "enabled" {
  description = "Set false to pause the schedule without destroying it."
  type        = bool
  default     = true
}

variable "description" {
  description = "Free-text description shown in the Scheduler console."
  type        = string
  default     = null
}
