variable "name" {
  description = "Base name for every resource, e.g. \"acme-prod\". The instance identifier, subnet group and security group are all \"<name>-db\" (and tagged Name = \"<name>-db\"); the parameter group is \"<name>-postgres<major>\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, start with a letter, and be 2-41 characters (RDS identifiers are capped at 63 and we append suffixes)."
  }
}

variable "vpc_id" {
  description = "VPC the database and its security group live in."
  type        = string
}

variable "subnet_ids" {
  description = "PRIVATE subnet IDs for the DB subnet group (at least two, in different AZs; RDS requires this even for Single-AZ)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "RDS subnet groups need at least two subnets in different Availability Zones."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups (ECS task SGs, bastion SG) allowed to open TCP 5432 to the database. Nothing else can connect."
  type        = list(string)
}

variable "engine_version" {
  description = "PostgreSQL engine version. A major-only value like \"18\" lets RDS pick the latest minor (auto_minor_version_upgrade keeps it current)."
  type        = string
  default     = "18"

  validation {
    condition     = can(regex("^[0-9]{2}(\\.[0-9]+)?$", var.engine_version))
    error_message = "engine_version must look like \"18\" or \"17.6\"."
  }
}

variable "parameter_group_family" {
  description = "DB parameter group family. Defaults to \"postgres<major>\" derived from engine_version; only set it if you need to override."
  type        = string
  default     = null
}

variable "instance_class" {
  description = "Instance class. db.t4g.micro (~$11.68/mo Single-AZ) fits most hobby/small apps; db.t4g.small (~$23/mo) when you see CPUCreditBalance or FreeableMemory alarms."
  type        = string
  default     = "db.t4g.micro"

  validation {
    condition     = can(regex("^db\\.[a-z0-9]+\\.[a-z0-9]+$", var.instance_class))
    error_message = "instance_class must look like \"db.t4g.micro\"."
  }
}

variable "allocated_storage" {
  description = "Initial gp3 storage in GiB. 20 is the minimum (~$2.30/mo at $0.115/GB-month)."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20 && var.allocated_storage <= 65536
    error_message = "allocated_storage must be between 20 and 65536 GiB."
  }
}

variable "max_allocated_storage" {
  description = "Upper bound for RDS storage autoscaling in GiB. Set 0 to disable. You only pay for what is actually allocated, so a generous ceiling is free insurance against a full disk."
  type        = number
  default     = 100

  validation {
    condition     = var.max_allocated_storage == 0 || var.max_allocated_storage >= var.allocated_storage
    error_message = "max_allocated_storage must be 0 (disabled) or >= allocated_storage."
  }
}

variable "multi_az" {
  description = "Run a synchronous standby in a second AZ. DOUBLES instance and storage cost (db.t4g.micro: ~$23/mo instead of ~$12) and gives 60-120 s automatic failover. false for dev/staging, consider true for prod."
  type        = bool
  default     = false
}

variable "db_name" {
  description = "Name of the initial database RDS creates."
  type        = string
  default     = "app"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.db_name))
    error_message = "db_name must start with a letter and contain only letters, digits and underscores (max 63 chars)."
  }
}

variable "master_username" {
  description = "Master user name. The password is generated and rotated by RDS in Secrets Manager; Terraform never sees it."
  type        = string
  default     = "postgres"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.master_username))
    error_message = "master_username must start with a letter and contain only letters, digits and underscores."
  }
}

variable "backup_retention_period" {
  description = "Days of automated backups / point-in-time recovery. 7 is a sensible floor; 14-35 for prod. Backup storage up to 100% of allocated storage is free."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be 1-35 days (0 would disable point-in-time recovery)."
  }
}

variable "backup_window" {
  description = "Daily UTC window for automated backups (hh24:mi-hh24:mi). Must not overlap maintenance_window."
  type        = string
  default     = "03:00-03:30"
}

variable "maintenance_window" {
  description = "Weekly UTC window for patches and minor version upgrades (ddd:hh24:mi-ddd:hh24:mi)."
  type        = string
  default     = "sun:04:00-sun:05:00"
}

variable "deletion_protection" {
  description = "Make the RDS API refuse DeleteDBInstance. Keep true in prod; the README explains the two-step teardown."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for storage encryption and the RDS-managed master secret. null uses the free AWS-managed keys (aws/rds, aws/secretsmanager). A CMK costs $1/month."
  type        = string
  default     = null
}

variable "alarm_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms. null disables alarm creation."
  type        = string
  default     = null
}

variable "connection_alarm_threshold" {
  description = "DatabaseConnections alarm threshold. db.t4g.micro (1 GiB) allows roughly 80-90 connections; alarm at ~70%."
  type        = number
  default     = 60
}

variable "apply_immediately" {
  description = "Apply modifications (instance class, storage, parameter changes) right away instead of in the next maintenance window. Immediate changes can cause a short outage; keep false in prod."
  type        = bool
  default     = false
}

variable "enable_performance_insights" {
  description = "Enable Database Insights in standard mode (7-day retention). Free for RDS PostgreSQL on every instance class, so there is no reason to turn it off except to minimise IAM/console noise."
  type        = bool
  default     = true
}

variable "enabled_cloudwatch_logs_exports" {
  description = "RDS log types to ship to CloudWatch Logs. [\"postgresql\"] is cheap (default Postgres logging is errors only, ~MBs/month) and is where you find failed-connection and slow-query details. [] turns it off."
  type        = list(string)
  default     = ["postgresql"]

  validation {
    condition     = alltrue([for l in var.enabled_cloudwatch_logs_exports : contains(["postgresql", "upgrade", "iam-db-auth-error"], l)])
    error_message = "Valid PostgreSQL log exports are \"postgresql\", \"upgrade\" and \"iam-db-auth-error\"."
  }
}

variable "log_retention_days" {
  description = "Retention for the exported RDS log groups. Pre-creating the groups with retention avoids CloudWatch's default of keeping logs forever."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the values CloudWatch Logs accepts (1, 3, 5, 7, 14, 30, 60, 90, ... 3653)."
  }
}

variable "extra_parameters" {
  description = "Additional DB parameters. Static parameters (e.g. shared_preload_libraries, max_connections) need apply_method = \"pending-reboot\"; dynamic ones can use \"immediate\" (the default)."
  type = map(object({
    value        = string
    apply_method = optional(string, "immediate")
  }))
  default = {}

  validation {
    condition     = alltrue([for p in values(var.extra_parameters) : contains(["immediate", "pending-reboot"], p.apply_method)])
    error_message = "apply_method must be \"immediate\" or \"pending-reboot\"."
  }
}
