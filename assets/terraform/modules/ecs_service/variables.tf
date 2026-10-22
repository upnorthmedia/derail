# ---------------------------------------------------------------------------
# Identity and placement
# ---------------------------------------------------------------------------

variable "name" {
  description = "Full service name, e.g. \"acme-prod-web\" or \"acme-prod-worker\". Used for the ECR repo, log group, roles, security group, task family and service."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, start with a letter, and be 2-41 characters."
  }
}

variable "cluster_arn" {
  description = "ARN of the ECS cluster. The cluster must have the FARGATE and FARGATE_SPOT capacity providers associated (aws_ecs_cluster_capacity_providers)."
  type        = string
}

variable "cluster_name" {
  description = "Name of the same ECS cluster (needed for autoscaling resource IDs and CloudWatch dimensions)."
  type        = string
}

variable "vpc_id" {
  description = "VPC for the task security group and target group."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the tasks. Public subnets + assign_public_ip = true is the cheap default; private subnets need a NAT gateway (~$33/mo) or VPC endpoints to pull images."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "At least one subnet is required."
  }
}

variable "assign_public_ip" {
  description = "Give each task a public IPv4 address (~$3.65/mo per running task). Required in public subnets without NAT so the task can reach ECR, Secrets Manager, CloudWatch and third-party APIs. Inbound is still blocked by the security group."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Image
# ---------------------------------------------------------------------------

variable "create_ecr_repository" {
  description = "Create an ECR repository named after the service and run image \"<repo>:<image_tag>\". Set false for a second service (worker) that reuses another service's image via var.image."
  type        = bool
  default     = true
}

variable "image_tag" {
  description = "Tag of the image to run from the module-created ECR repository. CI typically passes the git SHA. Ignored when create_ecr_repository = false."
  type        = string
  default     = "bootstrap"
}

variable "image" {
  description = "Full image reference (e.g. module.web.image) when create_ecr_repository = false. Must be null otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.create_ecr_repository ? var.image == null : var.image != null
    error_message = "Set image only when create_ecr_repository = false (and always set it in that case)."
  }
}

variable "ecr_force_delete" {
  description = "Allow terraform destroy to delete the ECR repository even if it still contains images. Keep false in prod."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Container and task sizing
# ---------------------------------------------------------------------------

variable "container_name" {
  description = "Name of the single application container inside the task. Scheduled tasks reference it in containerOverrides."
  type        = string
  default     = "app"
}

variable "container_port" {
  description = "Port the app listens on inside the container."
  type        = number
  default     = 3000

  validation {
    condition     = var.container_port >= 1 && var.container_port <= 65535
    error_message = "container_port must be between 1 and 65535."
  }
}

variable "cpu" {
  description = "Task CPU units (1024 = 1 vCPU). Fargate ARM64 pricing: 256 = ~$5.9/mo, 512 = ~$11.8/mo, 1024 = ~$23.6/mo of CPU alone (730 h)."
  type        = number
  default     = 512

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.cpu)
    error_message = "cpu must be one of 256, 512, 1024, 2048, 4096, 8192, 16384."
  }
}

variable "memory" {
  description = "Task memory in MiB. Must be a valid pairing with cpu (256: 512-2048; 512: 1024-4096; 1024: 2048-8192; 2048: 4096-16384). ~$2.6/GB-month on ARM64."
  type        = number
  default     = 1024

  validation {
    condition     = var.memory >= 512 && var.memory % 256 == 0
    error_message = "memory must be >= 512 MiB and a multiple of 256."
  }
}

variable "cpu_architecture" {
  description = "ARM64 (Graviton, ~20% cheaper) or X86_64. Your image must be built for this platform (docker buildx --platform linux/arm64)."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
}

variable "ephemeral_storage_gib" {
  description = "Task scratch disk in GiB. null = the 20 GiB included for free; 21-200 costs ~$0.11/GB-month extra."
  type        = number
  default     = null

  validation {
    condition     = var.ephemeral_storage_gib == null || (var.ephemeral_storage_gib >= 21 && var.ephemeral_storage_gib <= 200)
    error_message = "ephemeral_storage_gib must be null or between 21 and 200."
  }
}

variable "container_command" {
  description = "Override the image CMD (e.g. [\"node\", \"worker.js\"] for a queue consumer). null keeps the image default."
  type        = list(string)
  default     = null
}

variable "environment" {
  description = "Plain (non-secret) environment variables. Secrets go through var.secrets, never here: this map is visible in the task definition and in state."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Secrets injected at task start, as ECS expects them: [{ name = \"DATABASE_URL\", valueFrom = \"<secret arn>:DATABASE_URL::\" }]. Use the secrets module's ecs_secrets output."
  type = list(object({
    name      = string
    valueFrom = string
  }))
  default = []
}

variable "secret_arns" {
  description = "Secrets Manager secret ARNs the execution role may read (the containers of the entries in var.secrets)."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN that encrypts the secrets and/or the log group. Grants kms:Decrypt to the execution role. null when using AWS-managed keys."
  type        = string
  default     = null
}

variable "stop_timeout" {
  description = "Seconds between SIGTERM and SIGKILL when a task stops. Give in-flight requests time to finish; max 120 on Fargate."
  type        = number
  default     = 30

  validation {
    condition     = var.stop_timeout >= 2 && var.stop_timeout <= 120
    error_message = "stop_timeout must be between 2 and 120 seconds."
  }
}

variable "linux_init_process" {
  description = "Run a tiny init (tini) as PID 1 so signals are forwarded and zombie processes are reaped. Required for ECS Exec to behave; harmless otherwise."
  type        = bool
  default     = true
}

variable "enable_execute_command" {
  description = "Allow `aws ecs execute-command` shells into running tasks (SSM Session Manager). Handy in dev/staging; off by default for prod. Only new tasks pick up a change."
  type        = bool
  default     = false
}

variable "task_policy_json" {
  description = "Optional IAM policy document (JSON string) attached to the TASK role: what your application code may call (S3 bucket, SES, SQS). null = no extra permissions."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Load balancer exposure
# ---------------------------------------------------------------------------

variable "expose_http" {
  description = "Register the service behind the ALB (target group + listener rule + ALB-based alarms). false for workers."
  type        = bool
  default     = true
}

variable "https_listener_arn" {
  description = "ARN of the ALB :443 listener (alb_https output). Required when expose_http = true."
  type        = string
  default     = null

  validation {
    condition     = !var.expose_http || var.https_listener_arn != null
    error_message = "https_listener_arn is required when expose_http = true."
  }
}

variable "alb_security_group_id" {
  description = "ALB security group ID; the task SG accepts container_port only from it. Required when expose_http = true."
  type        = string
  default     = null

  validation {
    condition     = !var.expose_http || var.alb_security_group_id != null
    error_message = "alb_security_group_id is required when expose_http = true."
  }
}

variable "host_headers" {
  description = "Hostnames this service answers for, e.g. [\"app.example.com\"]. Becomes the host-header condition of the listener rule. Required when expose_http = true."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.expose_http || length(var.host_headers) > 0
    error_message = "host_headers must contain at least one hostname when expose_http = true."
  }
}

variable "listener_rule_priority" {
  description = "Priority of the listener rule (1-50000, unique per listener). Lower wins. Pick a distinct number per service sharing the ALB."
  type        = number
  default     = 100

  validation {
    condition     = var.listener_rule_priority >= 1 && var.listener_rule_priority <= 50000
    error_message = "listener_rule_priority must be between 1 and 50000."
  }
}

variable "health_check_path" {
  description = "HTTP path used by the ALB target group and the container health check. Must return 2xx/3xx quickly without touching external services."
  type        = string
  default     = "/api/health"

  validation {
    condition     = startswith(var.health_check_path, "/")
    error_message = "health_check_path must start with \"/\"."
  }
}

variable "health_check_grace_period_seconds" {
  description = "Seconds after a task starts during which failing ALB health checks are ignored (slow Next.js boot). Also used as the container health check startPeriod."
  type        = number
  default     = 60

  validation {
    condition     = var.health_check_grace_period_seconds >= 0 && var.health_check_grace_period_seconds <= 300
    error_message = "health_check_grace_period_seconds must be between 0 and 300."
  }
}

variable "enable_container_health_check" {
  description = "Add a Docker-level health check inside the task definition (wget/curl/node against health_check_path). Gives the circuit breaker a signal before ALB registration. Only applies when expose_http = true."
  type        = bool
  default     = true
}

variable "container_health_check_command" {
  description = "Override the container health check command (full ECS form, e.g. [\"CMD-SHELL\", \"python -c '...' || exit 1\"]). null = built-in wget -> curl -> node fetch fallback chain."
  type        = list(string)
  default     = null
}

# ---------------------------------------------------------------------------
# Scaling and deployment
# ---------------------------------------------------------------------------

variable "desired_count" {
  description = "Initial number of tasks. After the first apply autoscaling owns this number (lifecycle ignore_changes)."
  type        = number
  default     = 1
}

variable "min_capacity" {
  description = "Autoscaling floor. 1 for budget; 2 for production (survives an AZ or task failure without a gap)."
  type        = number
  default     = 1

  validation {
    condition     = var.min_capacity >= 0
    error_message = "min_capacity must be >= 0."
  }
}

variable "max_capacity" {
  description = "Autoscaling ceiling. Your worst-case monthly bill is max_capacity x task price."
  type        = number
  default     = 2

  validation {
    condition     = var.max_capacity >= var.min_capacity
    error_message = "max_capacity must be >= min_capacity."
  }
}

variable "autoscaling_target_cpu" {
  description = "Target average CPU % for target-tracking scaling. 60-70 is the usual sweet spot."
  type        = number
  default     = 70

  validation {
    condition     = var.autoscaling_target_cpu > 0 && var.autoscaling_target_cpu <= 100
    error_message = "autoscaling_target_cpu must be between 1 and 100."
  }
}

variable "autoscaling_target_requests_per_target" {
  description = "Optional second target-tracking policy on ALBRequestCountPerTarget (requests per minute per task). null disables it. Only applies when expose_http = true."
  type        = number
  default     = null
}

variable "capacity_provider" {
  description = "FARGATE (on-demand) or FARGATE_SPOT (up to 70% cheaper, can be interrupted with 2 minutes notice). Use SPOT for workers, never for a single-task web service."
  type        = string
  default     = "FARGATE"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT"], var.capacity_provider)
    error_message = "capacity_provider must be FARGATE or FARGATE_SPOT."
  }
}

variable "deployment_minimum_healthy_percent" {
  description = "Minimum % of desired tasks that must stay running during a deployment. 100 keeps the old task up until the new one is healthy (zero-downtime with 1 task)."
  type        = number
  default     = 100

  validation {
    condition     = var.deployment_minimum_healthy_percent >= 0 && var.deployment_minimum_healthy_percent <= 100
    error_message = "deployment_minimum_healthy_percent must be between 0 and 100."
  }
}

variable "deployment_maximum_percent" {
  description = "Maximum % of desired tasks that may run during a deployment. 200 allows a full extra set of tasks (briefly doubles compute cost during a rollout)."
  type        = number
  default     = 200

  validation {
    condition     = var.deployment_maximum_percent >= 100 && var.deployment_maximum_percent <= 200
    error_message = "deployment_maximum_percent must be between 100 and 200."
  }
}

variable "deployment_alarm_rollback" {
  description = "Also roll back a deployment when the target-5xx alarm fires during the bake window (~10 min with the alarm's 2 x 5 min periods). Requires alarm_topic_arn and expose_http. Makes every deploy take longer to be declared done."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the container log group. 14 for dev, 30-90 for prod. Logs: $0.50/GB ingested, $0.03/GB-month stored, 5 GB/month free."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the values CloudWatch Logs accepts (1, 3, 5, 7, 14, 30, 60, 90, ... 3653)."
  }
}

variable "alarm_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms (5xx, unhealthy hosts, CPU, memory). null disables alarm creation."
  type        = string
  default     = null
}
