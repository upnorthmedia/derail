# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
variable "platform_name" {
  type        = string
  description = "Name of the shared platform. Must equal the network root's platform_name (the VPC is found by tag Name = \"<platform_name>-vpc\"). Everything here is named after it: cluster \"<platform_name>\", ALB \"<platform_name>-alb\", database \"<platform_name>-db\". Project roots find these by name/tag, so change it only together with their platform_name."
  default     = "platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}$", var.platform_name))
    error_message = "platform_name must be 2-23 chars, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "environment" {
  type        = string
  description = "Environment tag for the shared platform. It is shared by every project, so prod is the honest default."
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "repository" {
  type        = string
  description = "Git repository holding this code, e.g. github.com/acme/infra (Repository tag)."

  validation {
    condition     = can(regex("^github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.repository))
    error_message = "repository must look like github.com/org/repo."
  }
}

variable "aws_region" {
  type        = string
  description = "Region of the shared VPC and of every project root that will use this platform."
  default     = "us-east-1"
}

# ---------------------------------------------------------------------------
# Shared load balancer
# ---------------------------------------------------------------------------
variable "create_shared_alb" {
  type        = bool
  description = "Create the shared Application Load Balancer (~$25/month fixed, however many projects use it). Projects opt in with shared_alb = true. false if every project keeps its own ALB."
  default     = true
}

variable "platform_domain_name" {
  type        = string
  description = "Hostname the platform itself owns on the shared ALB, e.g. apps.example-agency.com. The HTTPS listener needs a default certificate, so the platform must own one name; it serves a plain 404 (\"no rule matched\"). Projects attach their own certificates (SNI) and host-header rules. Must live inside platform_hosted_zone_name. Only used when create_shared_alb = true, but always required so the root has one fixed identity."

  validation {
    condition     = can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", var.platform_domain_name))
    error_message = "platform_domain_name must be a lowercase FQDN such as apps.example-agency.com."
  }
}

variable "platform_hosted_zone_name" {
  type        = string
  description = "Existing public Route 53 hosted zone that contains platform_domain_name, e.g. example-agency.com. Used for the ACM validation CNAMEs and the alias record. Only used when create_shared_alb = true."

  validation {
    condition     = can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", var.platform_hosted_zone_name))
    error_message = "platform_hosted_zone_name must be a lowercase DNS name such as example-agency.com."
  }
}

variable "alb_idle_timeout" {
  type        = number
  description = "Idle connection timeout of the shared ALB in seconds. Shared by every project: pick the largest value any tenant needs (long polling, slow uploads)."
  default     = 60

  validation {
    condition     = var.alb_idle_timeout >= 1 && var.alb_idle_timeout <= 4000
    error_message = "alb_idle_timeout must be between 1 and 4000 seconds."
  }
}

# ---------------------------------------------------------------------------
# Shared database
# ---------------------------------------------------------------------------
variable "create_shared_database" {
  type        = bool
  description = "Create the shared RDS PostgreSQL instance. Projects opt in with shared_database = true and get their own database + roles inside it. false if every project keeps its own instance."
  default     = true
}

variable "db_instance_class" {
  type        = string
  description = "Instance class of the shared database. db.t4g.small (~$23/month, 2 GiB, max_connections ~190) is the sensible floor for several tenants; db.t4g.medium (~$47, 4 GiB) when FreeableMemory or CPUCreditBalance alarms fire."
  default     = "db.t4g.small"

  validation {
    condition     = can(regex("^db\\.[a-z0-9]+\\.[a-z0-9]+$", var.db_instance_class))
    error_message = "db_instance_class must look like \"db.t4g.small\"."
  }
}

variable "db_engine_version" {
  type        = string
  description = "PostgreSQL major (or major.minor) of the shared instance. Every tenant shares it: a project whose source database runs a different major must be dumped/restored across majors (works, but test it) or get its own instance."
  default     = "18"

  validation {
    condition     = can(regex("^[0-9]{2}(\\.[0-9]+)?$", var.db_engine_version))
    error_message = "db_engine_version must look like \"18\" or \"17.6\"."
  }
}

variable "db_allocated_storage" {
  type        = number
  description = "Initial gp3 storage in GiB for the shared instance (~$0.115/GiB-month). Autoscaling grows it up to db_max_allocated_storage."
  default     = 20

  validation {
    condition     = var.db_allocated_storage >= 20
    error_message = "db_allocated_storage must be at least 20 GiB (RDS gp3 minimum)."
  }
}

variable "db_max_allocated_storage" {
  type        = number
  description = "Storage autoscaling ceiling in GiB. You only pay for what is allocated; the ceiling is insurance against one tenant filling the disk for everyone."
  default     = 200

  validation {
    condition     = var.db_max_allocated_storage == 0 || var.db_max_allocated_storage >= var.db_allocated_storage
    error_message = "db_max_allocated_storage must be 0 (disabled) or >= db_allocated_storage."
  }
}

variable "db_multi_az" {
  type        = bool
  description = "Synchronous standby in a second AZ for the shared instance. DOUBLES its price (~$47/month for db.t4g.small) but a failover then takes 1-2 minutes instead of a restore. Worth more here than for a single project, because an outage hits every tenant at once."
  default     = false
}

variable "db_backup_retention_period" {
  type        = number
  description = "Days of automated backups / point-in-time recovery for the shared instance. Backups cover every tenant's database at once (restores are per instance, see the README)."
  default     = 7

  validation {
    condition     = var.db_backup_retention_period >= 1 && var.db_backup_retention_period <= 35
    error_message = "db_backup_retention_period must be 1-35 days."
  }
}

variable "db_connection_alarm_threshold" {
  type        = number
  description = "DatabaseConnections alarm threshold for the shared instance. ~0.7 x max_connections: 130 for db.t4g.small (~190), 60 for db.t4g.micro (~85), 280 for db.t4g.medium (~400)."
  default     = 130

  validation {
    condition     = var.db_connection_alarm_threshold > 0
    error_message = "db_connection_alarm_threshold must be positive."
  }
}

variable "deletion_protection" {
  type        = bool
  description = "Deletion protection on the shared database and the shared ALB. true protects every tenant at once; set false in a dedicated apply only when decommissioning the whole platform."
  default     = true
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
variable "container_insights" {
  type        = string
  description = "ECS Container Insights on the shared cluster: disabled (free), enabled (~$1-3/month per service in custom metrics, for every tenant service), enhanced (more metrics, more cost)."
  default     = "disabled"

  validation {
    condition     = contains(["disabled", "enabled", "enhanced"], var.container_insights)
    error_message = "container_insights must be disabled, enabled or enhanced."
  }
}

# ---------------------------------------------------------------------------
# Alerts and budget
# ---------------------------------------------------------------------------
variable "alert_email" {
  type        = string
  description = "Address that receives the shared platform's budget, anomaly and RDS alarm emails (confirm the SNS subscription once)."

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "monthly_budget_usd" {
  type        = number
  description = "Monthly budget for everything tagged Project = <platform_name> (this root plus network/ and bootstrap/). Alerts at 80% actual and 100% forecast. Defaults cost ~$55/month (ALB + db.t4g.small); 100 leaves room for storage growth and a NAT gateway."
  default     = 100

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be positive."
  }
}
