variable "name" {
  description = "Base name, e.g. \"acme-prod\". The replication group becomes \"<name>-cache\" (ElastiCache caps ids at 40 characters)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,33}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, start with a letter, and be at most 34 characters so \"<name>-cache\" fits the 40-character ElastiCache limit."
  }
}

variable "vpc_id" {
  description = "VPC for the cache security group."
  type        = string
}

variable "subnet_ids" {
  description = "PRIVATE subnet IDs for the cache subnet group (at least two, in different AZs)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "ElastiCache subnet groups need at least two subnets in different Availability Zones."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups (ECS task SGs, migration host SG) allowed to open TCP 6379 to the cache. This list IS the authentication boundary: there is no AUTH token (see README). Append new entries at the end; the rules are count-indexed."
  type        = list(string)
}

variable "engine_version" {
  description = "Valkey engine version. \"8.0\" is current; the parameter group family is derived from the major (\"valkey8\")."
  type        = string
  default     = "8.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.engine_version))
    error_message = "engine_version must look like \"8.0\" or \"7.2\"."
  }
}

variable "node_type" {
  description = "Cache node class. cache.t4g.micro (0.5 GiB, ~$11.68/mo in us-east-1) is enough for a job queue or session cache of a Railway-sized app; cache.t4g.small (1.37 GiB, ~$23) when DatabaseMemoryUsagePercentage alarms."
  type        = string
  default     = "cache.t4g.micro"

  validation {
    condition     = can(regex("^cache\\.[a-z0-9]+\\.[a-z0-9]+$", var.node_type))
    error_message = "node_type must look like \"cache.t4g.micro\"."
  }
}

variable "num_cache_clusters" {
  description = "Number of nodes (1 primary + N-1 replicas). 1 = single node, no failover (fine for queues and caches that tolerate a few minutes of loss). 2+ enables automatic failover and Multi-AZ and doubles the cost."
  type        = number
  default     = 1

  validation {
    condition     = var.num_cache_clusters >= 1 && var.num_cache_clusters <= 6
    error_message = "num_cache_clusters must be between 1 and 6."
  }
}

variable "maxmemory_policy" {
  description = "What Valkey does when memory is full. \"noeviction\" (default) for job queues/brokers (BullMQ, Celery, Sidekiq): refuse writes rather than silently drop jobs. \"allkeys-lru\" for a pure cache. \"volatile-lru\" if you mix both and set TTLs on cache keys."
  type        = string
  default     = "noeviction"

  validation {
    condition     = contains(["noeviction", "allkeys-lru", "allkeys-lfu", "volatile-lru", "volatile-lfu", "allkeys-random", "volatile-random", "volatile-ttl"], var.maxmemory_policy)
    error_message = "maxmemory_policy must be a valid Valkey/Redis eviction policy (noeviction, allkeys-lru, allkeys-lfu, volatile-lru, volatile-lfu, allkeys-random, volatile-random, volatile-ttl)."
  }
}

variable "extra_parameters" {
  description = "Additional parameter group entries, e.g. { \"notify-keyspace-events\" = \"Ex\" } for BullMQ delayed jobs."
  type        = map(string)
  default     = {}
}

variable "snapshot_retention_limit" {
  description = "Days of automatic daily snapshots to keep. 0 disables backups (acceptable for a cache or a broker whose jobs are re-enqueueable). t4g.micro supports snapshots; backup storage is free up to the cache size."
  type        = number
  default     = 1

  validation {
    condition     = var.snapshot_retention_limit >= 0 && var.snapshot_retention_limit <= 35
    error_message = "snapshot_retention_limit must be 0-35 days."
  }
}

variable "snapshot_window" {
  description = "Daily UTC window for the automatic snapshot (hh24:mi-hh24:mi). Must not overlap maintenance_window."
  type        = string
  default     = "02:00-03:00"
}

variable "maintenance_window" {
  description = "Weekly UTC window for patches (ddd:hh24:mi-ddd:hh24:mi). Single-node groups are briefly unavailable during it."
  type        = string
  default     = "sun:03:30-sun:04:30"
}

variable "apply_immediately" {
  description = "Apply node type / engine changes right away instead of in the next maintenance window. Keep false in prod."
  type        = bool
  default     = false
}

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key for encryption at rest. null uses the free AWS-managed key."
  type        = string
  default     = null
}

variable "alarm_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms (CPU, memory, evictions). null disables alarm creation."
  type        = string
  default     = null
}

variable "memory_alarm_threshold_percent" {
  description = "DatabaseMemoryUsagePercentage above which the memory alarm fires. With noeviction, 100% means the broker refuses writes."
  type        = number
  default     = 80

  validation {
    condition     = var.memory_alarm_threshold_percent > 0 && var.memory_alarm_threshold_percent <= 100
    error_message = "memory_alarm_threshold_percent must be between 1 and 100."
  }
}
