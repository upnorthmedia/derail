# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
variable "project" {
  type        = string
  description = "Short slug for this project; used in every resource name and as the Project cost-allocation tag."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}$", var.project))
    error_message = "project must be 2-23 chars of lowercase letters, digits and hyphens, starting with a letter (ALB/RDS name limits)."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment. One root directory per environment."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "aws_region" {
  type        = string
  description = "Region for everything except CloudFront certificates/WAF (always us-east-1)."
  default     = "us-east-1"
}

variable "repository" {
  type        = string
  description = "Source repository in the form github.com/<org>/<repo>; used for the Repository tag."

  validation {
    condition     = can(regex("^github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.repository))
    error_message = "repository must look like github.com/org/repo."
  }
}

variable "github_org" {
  type        = string
  description = "GitHub organisation or user that owns the repository (OIDC trust policy)."
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name (OIDC trust policy)."
}

# MUST match the `environment:` key of the apply job in
# .github/workflows/terraform.yml (currently `prod`). With an environment on the
# job, GitHub's OIDC subject is repo:<org>/<repo>:environment:prod instead of
# ref:refs/heads/main; if the role does not trust that subject the FIRST apply
# from CI fails with "Not authorized to perform sts:AssumeRoleWithWebIdentity".
# null disables the environment subject (only for a workflow with no
# `environment:` on the apply job).
variable "github_environment" {
  type        = string
  description = "GitHub Environment name whose jobs may assume the apply role. Must equal the apply job's `environment:` in terraform.yml (\"prod\"); null trusts only plain pushes to the apply branch."
  default     = "prod"
}

variable "github_repository_ids" {
  type = object({
    owner_id = number
    repo_id  = number
  })
  description = "Optional numeric GitHub owner/repo IDs, needed only if the repo opted into immutable OIDC subject claims (repo:org@id/repo@id:...)."
  default     = null
}

variable "platform_name" {
  type        = string
  description = "platform_name used by the shared network and platform roots: the VPC is found by the tag Name=<platform_name>-vpc, the shared cluster by name, the shared ALB by tag Name=<platform_name>-alb and the shared database by identifier <platform_name>-db."
  default     = "platform"
}

# ---------------------------------------------------------------------------
# Shared platform (agency mode). Each flag swaps a per-project resource for a
# lookup of the one the platform/ root created. Default false = the project
# owns everything, exactly as before.
# ---------------------------------------------------------------------------
variable "shared_cluster" {
  type        = bool
  description = "true: run the services in the shared ECS cluster named <platform_name> (platform/ root) instead of creating cluster <project>-<env>. Clusters are free; sharing only reduces console noise, and the deploy role can then list (not change) other tenants' tasks."
  default     = false
}

variable "shared_alb" {
  type        = bool
  description = "true: do not create an ALB; attach this project's own ACM certificate (SNI) and host-header rules to the shared ALB <platform_name>-alb from the platform/ root. Saves ~$25/month per project. listener_rule_priority must then be unique across every project on that ALB."
  default     = false
}

variable "listener_rule_priority" {
  type        = number
  description = "Priority of this project's host-header rule on the HTTPS listener. The www/additional-name redirect rule uses listener_rule_priority + 1. MUST be unique per project on a shared ALB (two projects with the same number fail at apply with PriorityInUse): keep the allocation table in platform/README.md. Irrelevant on a dedicated ALB."
  default     = 100

  validation {
    condition     = var.listener_rule_priority >= 1 && var.listener_rule_priority <= 49999
    error_message = "listener_rule_priority must be between 1 and 49999 (the redirect rule takes priority + 1, and ALB priorities stop at 50000)."
  }
}

variable "shared_database" {
  type        = bool
  description = "true: do not create an RDS instance; use a database named shared_db_name inside the shared instance <platform_name>-db (platform/ root). The db_instance_class / db_engine_version / db_allocated_storage / db_multi_az variables are then ignored. The project's database and roles are created out-of-band with scripts/pg_migrate.sh (README)."
  default     = false
}

variable "shared_db_name" {
  type        = string
  description = "Name of this project's database inside the shared instance (shared_database = true). null = project with hyphens replaced by underscores (\"acme-shop\" -> \"acme_shop\"). Ignored when shared_database = false."
  default     = null

  validation {
    condition     = var.shared_db_name == null || can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", coalesce(var.shared_db_name, "x")))
    error_message = "shared_db_name must start with a letter and contain only letters, digits and underscores (max 63 chars)."
  }
}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------
variable "domain_name" {
  type        = string
  description = "Public hostname of the app, e.g. app.example.com. Must live inside hosted_zone_name."

  validation {
    condition     = can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a lowercase FQDN such as app.example.com."
  }
}

variable "hosted_zone_name" {
  type        = string
  description = "Route 53 public hosted zone that contains domain_name, e.g. example.com. Looked up when create_hosted_zone = false, created by this root when true."
}

variable "create_hosted_zone" {
  type        = bool
  description = "true: this root creates the Route 53 public hosted zone for hosted_zone_name (prevent_destroy) and outputs its name servers for the registrar. false: an existing zone is looked up. Set true when DNS currently lives at Vercel/Cloudflare/the registrar and this is the first project on the domain."
  default     = false
}

variable "traffic_target" {
  type        = string
  description = "Where the public records for domain_name and additional_domain_names point. \"old\": NO records pointing at AWS are created (old_platform_records are served instead), so the zone can be delegated to Route 53 days before cutover. \"aws\": alias records to CloudFront/the ALB. Cutover = set \"aws\" and apply; rollback = set \"old\" and apply. Both take one DNS TTL (60 s)."
  default     = "old"

  validation {
    condition     = contains(["old", "aws"], var.traffic_target)
    error_message = "traffic_target must be \"old\" or \"aws\"."
  }
}

variable "additional_domain_names" {
  type        = list(string)
  description = "Extra public hostnames that must also work, e.g. [\"www.example.com\"]. They are added to the certificate (CloudFront or ALB), get records when traffic_target = \"aws\", and are 301-redirected to domain_name (CloudFront Function when enable_cloudfront, ALB listener rule otherwise). Must live inside hosted_zone_name."
  default     = []

  validation {
    condition     = alltrue([for d in var.additional_domain_names : can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", d))])
    error_message = "additional_domain_names must be lowercase FQDNs such as www.example.com."
  }
}

variable "old_platform_records" {
  type = map(object({
    type    = string
    records = list(string)
    ttl     = optional(number, 60)
  }))
  description = "Records served for the public hostnames WHILE traffic_target = \"old\", keyed by hostname: what the old DNS provider has today, e.g. { \"example.com\" = { type = \"A\", records = [\"76.76.21.21\"] }, \"www.example.com\" = { type = \"CNAME\", records = [\"cname.vercel-dns.com\"] } }. They are removed when traffic_target flips to \"aws\" and recreated on rollback. Leave empty if the zone is only delegated at cutover time."
  default     = {}

  validation {
    condition     = alltrue([for r in values(var.old_platform_records) : contains(["A", "AAAA", "CNAME"], r.type)])
    error_message = "old_platform_records types must be A, AAAA or CNAME (a CNAME is not allowed at the zone apex; use the old platform's A records there)."
  }
}

variable "extra_dns_records" {
  type = map(object({
    type    = string
    records = list(string)
    ttl     = optional(number, 3600)
    name    = optional(string)
  }))
  description = "Every OTHER record in the old DNS provider that must keep working after the NS move: MX, SPF/DKIM/DMARC TXT, domain-verification TXT, CAA, CNAMEs for mail/analytics tools. Key = record name (FQDN; the apex for apex records) unless `name` overrides it (use that when the same name needs two types). Copy them BEFORE delegating; anything missing stops resolving the moment Route 53 becomes authoritative."
  default     = {}

  validation {
    condition     = alltrue([for r in values(var.extra_dns_records) : contains(["A", "AAAA", "CNAME", "MX", "TXT", "CAA", "SRV", "NS"], r.type)])
    error_message = "extra_dns_records types must be one of A, AAAA, CNAME, MX, TXT, CAA, SRV, NS."
  }
}

# ---------------------------------------------------------------------------
# Alerts and budget
# ---------------------------------------------------------------------------
variable "alert_email" {
  type        = string
  description = "Address that receives budget, anomaly and CloudWatch alarm emails (confirm the SNS subscription email once)."

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "monthly_budget_usd" {
  type        = number
  description = "Monthly cost budget for this project (filtered on the Project tag). Alerts at 80% actual and 100% forecast."
  default     = 100

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be positive."
  }
}

# ---------------------------------------------------------------------------
# Application container
# ---------------------------------------------------------------------------
variable "image_tag" {
  type        = string
  description = "Image tag to deploy from the project's ECR repository. CI passes the git SHA with -var image_tag=...; \"bootstrap\" is a placeholder for the very first apply before any image exists."
  default     = "bootstrap"
}

variable "container_port" {
  type        = number
  description = "Port the container listens on."
  default     = 3000

  validation {
    condition     = var.container_port > 0 && var.container_port < 65536
    error_message = "container_port must be between 1 and 65535."
  }
}

variable "health_check_path" {
  type        = string
  description = "Path the ALB probes. Must return 200-399 without auth and without touching the DB."
  default     = "/api/health"

  validation {
    condition     = startswith(var.health_check_path, "/")
    error_message = "health_check_path must start with /."
  }
}

variable "cpu" {
  type        = number
  description = "Fargate task CPU units (256 = 0.25 vCPU). Valid pairs with memory: 256/512-2048, 512/1024-4096, 1024/2048-8192."
  default     = 512

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.cpu)
    error_message = "cpu must be one of 256, 512, 1024, 2048, 4096, 8192, 16384."
  }
}

variable "memory" {
  type        = number
  description = "Fargate task memory in MiB for the web task. 1024 fits most small Node/Python apps; 2048 for memory-hungry ones (large CMS admin bundles, image processing). Must be a valid pair with cpu."
  default     = 1024

  validation {
    condition     = var.memory >= 512 && var.memory % 256 == 0
    error_message = "memory must be >= 512 and a multiple of 256."
  }
}

variable "desired_count" {
  type        = number
  description = "Initial number of web tasks. Autoscaling owns it afterwards (ignore_changes in the module)."
  default     = 1
}

variable "min_capacity" {
  type        = number
  description = "Autoscaling floor for the web service. 2 for zero-downtime deploys across AZs; 1 to save ~$15/month."
  default     = 1
}

variable "max_capacity" {
  type        = number
  description = "Autoscaling ceiling for the web service."
  default     = 4

  validation {
    condition     = var.max_capacity >= var.min_capacity
    error_message = "max_capacity must be >= min_capacity."
  }
}

variable "capacity_provider" {
  type        = string
  description = "FARGATE (on-demand) or FARGATE_SPOT (up to 70% cheaper, tasks can be interrupted with 2 min notice; fine for dev/staging)."
  default     = "FARGATE"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT"], var.capacity_provider)
    error_message = "capacity_provider must be FARGATE or FARGATE_SPOT."
  }
}

variable "task_in_public_subnets" {
  type        = bool
  description = "true: tasks get a public IP in the public subnets and reach the internet directly (no NAT gateway; ~$3.65/month per task IPv4). false: tasks run in private subnets and need the network root's NAT gateway (~$33/month + $0.045/GB) or VPC endpoints."
  default     = true
}

variable "container_insights" {
  type        = string
  description = "ECS cluster Container Insights: disabled (free), enabled (~$1-3/month per service in custom metrics), enhanced (more metrics, more cost)."
  default     = "disabled"

  validation {
    condition     = contains(["disabled", "enabled", "enhanced"], var.container_insights)
    error_message = "container_insights must be disabled, enabled or enhanced."
  }
}

variable "enable_execute_command" {
  type        = bool
  description = "Allow `aws ecs execute-command` shells into running tasks (the Railway shell equivalent). Adds SSM permissions to the task role."
  default     = false
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention for app logs. Ingestion is $0.50/GB; storage $0.03/GB-month."
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the CloudWatch Logs retention values (1, 3, 5, 7, 14, 30, 60, 90, ... 3653)."
  }
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
variable "db_instance_class" {
  type        = string
  description = "RDS instance class. db.t4g.micro (~$12/month) is enough for most Railway-sized apps; db.t4g.small (~$24) if memory-bound. Ignored when shared_database = true (the platform root sizes the shared instance)."
  default     = "db.t4g.micro"

  validation {
    condition     = startswith(var.db_instance_class, "db.")
    error_message = "db_instance_class must start with db. (e.g. db.t4g.micro)."
  }
}

variable "db_engine_version" {
  type        = string
  description = "PostgreSQL major (or major.minor) version. Must equal the SOURCE database's major (check with `SELECT version()` on the old platform): a pg_dump/pg_restore across majors works but changes behaviour, and extensions must exist for the target major. Ignored when shared_database = true (the shared instance's version is read from AWS and also drives the migration host's client major)."
  default     = "18"
}

variable "db_allocated_storage" {
  type        = number
  description = "Initial gp3 storage in GiB (20 is the minimum; ~$2.30/month). Storage autoscaling grows it to the module's max_allocated_storage. Ignored when shared_database = true."
  default     = 20

  validation {
    condition     = var.db_allocated_storage >= 20
    error_message = "db_allocated_storage must be at least 20 GiB (RDS gp3 minimum)."
  }
}

variable "db_multi_az" {
  type        = bool
  description = "Synchronous standby in a second AZ. Doubles the instance price; worth it only when a few minutes of downtime during a failure costs more than ~$12-25/month. Ignored when shared_database = true."
  default     = false
}

variable "deletion_protection" {
  type        = bool
  description = "RDS deletion protection (and the ALB's) for the resources THIS root creates. Set false in a dedicated apply before decommissioning. Has no effect on a shared database/ALB (the platform root protects those)."
  default     = true
}

# ---------------------------------------------------------------------------
# Configuration and secrets
# ---------------------------------------------------------------------------
variable "secret_keys" {
  type        = list(string)
  description = "Environment variable names stored in the single app secret (Secrets Manager JSON), e.g. [\"DATABASE_URL\", \"SESSION_SECRET\", \"STRIPE_SECRET_KEY\"]. Values are written by scripts/put_secrets.sh, never by Terraform."
  default     = ["DATABASE_URL"]

  validation {
    condition     = alltrue([for k in var.secret_keys : can(regex("^[A-Z][A-Z0-9_]*$", k))])
    error_message = "secret_keys must be UPPER_SNAKE_CASE environment variable names."
  }
}

variable "plain_env" {
  type        = map(string)
  description = "Non-secret environment variables for the containers (visible in the task definition and state)."
  default     = {}
}

# ---------------------------------------------------------------------------
# Worker and cron
# ---------------------------------------------------------------------------
variable "enable_worker" {
  type        = bool
  description = "Run a second ECS service from the same image with worker_command (queues, websockets). Costs another Fargate task."
  default     = false
}

variable "worker_command" {
  type        = list(string)
  description = "Container command for the worker service, e.g. [\"node\", \"dist/worker.js\"] or [\"celery\", \"-A\", \"app\", \"worker\"]. Required (non-empty) when enable_worker = true."
  default     = []

  validation {
    condition     = !var.enable_worker || length(var.worker_command) > 0
    error_message = "worker_command must be a non-empty command when enable_worker = true."
  }
}

variable "worker_cpu" {
  type        = number
  description = "Fargate CPU units for the worker task. null = same as the web task (cpu)."
  default     = null

  validation {
    condition     = var.worker_cpu == null || contains([256, 512, 1024, 2048, 4096, 8192, 16384], coalesce(var.worker_cpu, 256))
    error_message = "worker_cpu must be null or one of 256, 512, 1024, 2048, 4096, 8192, 16384."
  }
}

variable "worker_memory" {
  type        = number
  description = "Fargate memory (MiB) for the worker task. null = same as the web task (memory). Must pair with worker_cpu."
  default     = null

  validation {
    condition     = var.worker_memory == null || (coalesce(var.worker_memory, 512) >= 512 && coalesce(var.worker_memory, 512) % 256 == 0)
    error_message = "worker_memory must be null or >= 512 and a multiple of 256."
  }
}

variable "worker_capacity_provider" {
  type        = string
  description = "FARGATE or FARGATE_SPOT for the worker. null = same as the web service (capacity_provider). Spot suits idempotent queue consumers; keep FARGATE for long jobs that cannot resume."
  default     = null

  validation {
    condition     = var.worker_capacity_provider == null || contains(["FARGATE", "FARGATE_SPOT"], coalesce(var.worker_capacity_provider, "FARGATE"))
    error_message = "worker_capacity_provider must be null, FARGATE or FARGATE_SPOT."
  }
}

variable "worker_desired_count" {
  type        = number
  description = "Initial number of worker tasks (autoscaling owns it afterwards)."
  default     = 1
}

variable "worker_min_capacity" {
  type        = number
  description = "Autoscaling floor for the worker service."
  default     = 1
}

variable "worker_max_capacity" {
  type        = number
  description = "Autoscaling ceiling for the worker service (CPU target tracking)."
  default     = 2

  validation {
    condition     = var.worker_max_capacity >= var.worker_min_capacity
    error_message = "worker_max_capacity must be >= worker_min_capacity."
  }
}

variable "cron_jobs" {
  type = map(object({
    schedule = string
    command  = list(string)
  }))
  description = "Scheduled one-off tasks using the web image: name => { schedule = \"cron(0 5 * * ? *)\" or \"rate(1 hour)\", command = [\"node\", \"scripts/x.js\"] }. EventBridge cron has 6 fields; see the scheduled_task README."
  default     = {}

  validation {
    condition     = alltrue([for k, v in var.cron_jobs : can(regex("^(cron|rate|at)\\(.+\\)$", v.schedule))])
    error_message = "Every cron_jobs schedule must be an EventBridge Scheduler expression: cron(...), rate(...) or at(...)."
  }
}

# Schedules are created DISABLED by default. Until cutover the old platform's
# crons still run against the live database; an enabled AWS copy would run the
# same jobs twice (double emails, double invoices) or run them against the
# frozen, half-restored RDS. Flip to true together with traffic_target = "aws".
variable "crons_enabled" {
  type        = bool
  description = "Whether the EventBridge schedules in cron_jobs actually fire. false (default) creates them paused so the AWS copy does not double-run jobs against the old platform or the frozen database before cutover; set true at cutover."
  default     = false
}

variable "cron_capacity_provider" {
  type        = string
  description = "FARGATE_SPOT (default, ~70% cheaper; a short job that can simply run again next time is the ideal Spot workload) or FARGATE for jobs that must not be interrupted."
  default     = "FARGATE_SPOT"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT"], var.cron_capacity_provider)
    error_message = "cron_capacity_provider must be FARGATE or FARGATE_SPOT."
  }
}

# ---------------------------------------------------------------------------
# Media and edge
# ---------------------------------------------------------------------------
variable "enable_media_bucket" {
  type        = bool
  description = "Create the S3 media bucket (replacement for Vercel Blob / Railway volumes) and grant the tasks access."
  default     = false
}

variable "media_cdn" {
  type        = bool
  description = "Put CloudFront in front of the media bucket for public reads (images, avatars). false = private bucket only; the app serves files with presigned URLs (documents, invoices) and MEDIA_URL is not set. Requires enable_media_bucket."
  default     = true
}

variable "media_domain_name" {
  type        = string
  description = "Optional custom hostname for media (e.g. cdn.example.com, inside hosted_zone_name). Null uses the CloudFront default domain. Ignored when media_cdn = false."
  default     = null
}

variable "enable_cloudfront" {
  type        = bool
  description = "Put CloudFront in front of the ALB (edge caching, HTTP/3, optional WAF). Usually $0 under the always-free tier."
  default     = false
}

variable "enable_waf" {
  type        = bool
  description = "Attach an AWS WAF web ACL to the CloudFront distribution (requires enable_cloudfront). ~$9/month pay-as-you-go, included in flat-rate plans."
  default     = false

  validation {
    condition     = !var.enable_waf || var.enable_cloudfront
    error_message = "enable_waf requires enable_cloudfront = true (the web ACL is attached to the distribution)."
  }
}

variable "waf_path_rate_limits" {
  type = list(object({
    path_prefix = string
    limit       = number
    name        = optional(string)
  }))
  description = "Per-path WAF rate limits (requests per IP per 5 minutes), e.g. [{ path_prefix = \"/api/auth/\", limit = 300 }] for login endpoints. Requires enable_waf. $1/month per entry."
  default     = []
}

variable "cloudfront_origin_request_policy_name" {
  type        = string
  description = "Origin request policy for every CloudFront behavior. \"Managed-AllViewer\" (default) forwards all viewer headers; \"Managed-AllViewerAndCloudFrontHeaders-2022-06\" also forwards CloudFront-Viewer-Country / -Address etc. when the app needs geolocation."
  default     = "Managed-AllViewer"

  validation {
    condition     = contains(["Managed-AllViewer", "Managed-AllViewerAndCloudFrontHeaders-2022-06", "Managed-AllViewerExceptHostHeader"], var.cloudfront_origin_request_policy_name)
    error_message = "cloudfront_origin_request_policy_name must be one of the managed AllViewer policies."
  }
}

variable "create_image_cache_policy" {
  type        = bool
  description = "Create the custom CloudFront cache policy for the Next.js image optimizer (/_next/image). Set false for non-Next.js apps and on CloudFront Free/Pro flat-rate plans (custom policies are not allowed there); images then fall through to the default behavior."
  default     = true
}

# ---------------------------------------------------------------------------
# Framework-specific environment
# ---------------------------------------------------------------------------
variable "framework" {
  type        = string
  description = "Shapes the baseline environment injected into every task (locals.tf base_env). nextjs: NODE_ENV, HOSTNAME=0.0.0.0, NEXT_TELEMETRY_DISABLED, NEXT_PUBLIC_SERVER_URL. node: NODE_ENV, HOSTNAME. python / other: only PORT, APP_URL and AWS_REGION. Add anything else through plain_env."
  default     = "nextjs"

  validation {
    condition     = contains(["nextjs", "node", "python", "other"], var.framework)
    error_message = "framework must be nextjs, node, python or other."
  }
}

# ---------------------------------------------------------------------------
# Cache / queue broker (ElastiCache for Valkey)
# ---------------------------------------------------------------------------
variable "enable_cache" {
  type        = bool
  description = "Create an ElastiCache for Valkey replication group (Railway Redis replacement: BullMQ/Celery broker, sessions, cache) and inject REDIS_URL (rediss://..., no password) into the tasks. ~$12/month for cache.t4g.micro."
  default     = false
}

variable "cache_node_type" {
  type        = string
  description = "ElastiCache node type. cache.t4g.micro (~$12/month, 0.5 GiB) or cache.t4g.small (~$23/month, 1.4 GiB)."
  default     = "cache.t4g.micro"

  validation {
    condition     = startswith(var.cache_node_type, "cache.")
    error_message = "cache_node_type must start with cache. (e.g. cache.t4g.micro)."
  }
}

variable "cache_maxmemory_policy" {
  type        = string
  description = "Valkey eviction policy. noeviction for a job queue/broker (never drop jobs silently), allkeys-lru for a pure cache."
  default     = "noeviction"

  validation {
    condition     = contains(["noeviction", "allkeys-lru", "allkeys-lfu", "volatile-lru", "volatile-lfu", "allkeys-random", "volatile-random", "volatile-ttl"], var.cache_maxmemory_policy)
    error_message = "cache_maxmemory_policy must be a valid Valkey eviction policy."
  }
}

# ---------------------------------------------------------------------------
# Data migration helpers (temporary)
# ---------------------------------------------------------------------------
variable "enable_migration_host" {
  type        = bool
  description = "Create the SSM-only EC2 host (modules/migration_host) used to run pg_dump/pg_restore inside the VPC. true for the rehearsal and cutover window, then false (destroys it). ~$5/month while it exists."
  default     = false
}

variable "migration_host_pg_major" {
  type        = number
  description = "PostgreSQL client major installed on the migration host. null = the major of db_engine_version."
  default     = null
}

variable "migration_host_instance_type" {
  type        = string
  description = "Instance type of the migration host. t4g.nano (~$3/month) drives a dump/restore of a few GB; t4g.small for parallel restores of larger databases."
  default     = "t4g.nano"
}

variable "migration_host_staging_bucket_arn" {
  type        = string
  description = "Optional S3 bucket ARN the migration host may read/write under the prefix migration/ (dump files, volume contents). null = no S3 access."
  default     = null
}

variable "enable_migration_task" {
  type        = bool
  description = "Register the \"<project>-<env>-tools\" task definition (migrations.tf): identical to the web task but running the tools image with migration_command. The deploy workflow RunTasks it before rolling the web service."
  default     = true
}

variable "tools_image_tag_suffix" {
  type        = string
  description = "Suffix appended to image_tag for the tools image (\"<sha>-tools\"), which the Dockerfile's tools stage builds with the migration CLI, devDependencies and psql. Empty string reuses the web image."
  default     = "-tools"
}

variable "migration_command" {
  type        = list(string)
  description = "Default command of the tools task definition (the workflow may override it per run), e.g. [\"npm\", \"run\", \"db:migrate\"], [\"npx\", \"prisma\", \"migrate\", \"deploy\"], [\"alembic\", \"upgrade\", \"head\"]."
  default     = ["npm", "run", "db:migrate"]

  validation {
    condition     = length(var.migration_command) > 0
    error_message = "migration_command must not be empty."
  }
}
