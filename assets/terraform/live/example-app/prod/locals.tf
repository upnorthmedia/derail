locals {
  name = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = var.repository
  }

  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # Where tasks run. Public subnets + public IP = no NAT gateway (~$33/month +
  # $0.045/GB) but each running task pays for one public IPv4 (~$3.65/month).
  # Private subnets need NAT (network root: enable_nat_gateway = true) or VPC
  # endpoints, otherwise image pulls and Secrets Manager calls fail.
  task_subnet_ids  = var.task_in_public_subnets ? data.aws_subnets.public.ids : data.aws_subnets.private.ids
  assign_public_ip = var.task_in_public_subnets

  # When CloudFront fronts the app it must connect to a hostname covered by the
  # ALB certificate, so the ALB gets a second name and CloudFront targets that.
  origin_domain_name = "origin.${var.domain_name}"

  # Names the ALB certificate must cover besides domain_name: origin.<domain>
  # when CloudFront is the public entry point (it owns www), otherwise the
  # additional names the ALB answers (and redirects) itself. Same list for the
  # dedicated ALB (module.alb) and the project's SNI certificate (shared.tf).
  alb_certificate_sans = var.enable_cloudfront ? [local.origin_domain_name] : var.additional_domain_names

  # ---------------------------------------------------------------------------
  # Shared platform indirection. Everything below this block uses these locals
  # and does not care whether the cluster / ALB / database is this project's
  # own or the platform root's.
  # ---------------------------------------------------------------------------
  cluster_arn  = var.shared_cluster ? data.aws_ecs_cluster.shared[0].arn : aws_ecs_cluster.this[0].arn
  cluster_name = var.shared_cluster ? data.aws_ecs_cluster.shared[0].cluster_name : aws_ecs_cluster.this[0].name

  https_listener_arn    = var.shared_alb ? data.aws_lb_listener.shared_https[0].arn : module.alb[0].https_listener_arn
  alb_security_group_id = var.shared_alb ? tolist(data.aws_lb.shared[0].security_groups)[0] : module.alb[0].security_group_id
  alb_dns_name          = var.shared_alb ? data.aws_lb.shared[0].dns_name : module.alb[0].alb_dns_name
  alb_zone_id           = var.shared_alb ? data.aws_lb.shared[0].zone_id : module.alb[0].alb_zone_id

  # Shared instance: the project's database lives inside it under
  # shared_db_name ("acme-shop" -> "acme_shop" unless overridden).
  shared_db_name       = coalesce(var.shared_db_name, replace(var.project, "-", "_"))
  db_address           = var.shared_database ? data.aws_db_instance.shared[0].address : module.db[0].address
  db_port              = var.shared_database ? data.aws_db_instance.shared[0].port : module.db[0].port
  db_name              = var.shared_database ? local.shared_db_name : module.db[0].db_name
  db_master_secret_arn = var.shared_database ? data.aws_db_instance.shared[0].master_user_secret[0].secret_arn : module.db[0].master_user_secret_arn
  db_engine_version    = var.shared_database ? data.aws_db_instance.shared[0].engine_version : var.db_engine_version

  # Route 53 zone: created by dns.tf or looked up by data.tf.
  hosted_zone_id = var.create_hosted_zone ? aws_route53_zone.this[0].zone_id : data.aws_route53_zone.this[0].zone_id

  # The cutover switch (dns.tf). While "old", the zone may already be
  # authoritative but the public hostnames keep resolving to the old platform;
  # the alias records to CloudFront / the ALB exist only when "aws".
  dns_points_to_aws = var.traffic_target == "aws"

  # When the app secret carries DATABASE_MIGRATE_URL, the migration task uses it
  # as DATABASE_URL (migrations.tf) so DDL runs as the owner role, not app_rw.
  has_migrate_url = contains(var.secret_keys, "DATABASE_MIGRATE_URL")

  # Name of the single container inside each task definition. Scheduled tasks
  # and the migration RunTask override this container's command.
  container_name = "app"

  # Environment every task gets, whatever the framework. var.plain_env wins on
  # conflicts. APP_URL is the canonical public origin for absolute links,
  # OAuth callbacks and webhook signature checks.
  common_env = {
    PORT       = tostring(var.container_port)
    APP_URL    = "https://${var.domain_name}"
    AWS_REGION = local.region
  }

  # Framework extras. HOSTNAME=0.0.0.0 matters for Node servers: `next start` /
  # standalone and several HTTP frameworks bind to localhost otherwise and the
  # ALB health check never succeeds. Python servers (uvicorn, gunicorn) take
  # the bind address on their command line instead.
  framework_env = {
    nextjs = {
      NODE_ENV                = "production"
      HOSTNAME                = "0.0.0.0"
      NEXT_TELEMETRY_DISABLED = "1"
      NEXT_PUBLIC_SERVER_URL  = "https://${var.domain_name}"
    }
    node = {
      NODE_ENV = "production"
      HOSTNAME = "0.0.0.0"
    }
    python = {}
    other  = {}
  }

  base_env = merge(local.common_env, local.framework_env[var.framework])

  # MEDIA_URL only exists when the bucket has a CDN; a private bucket is
  # addressed by name and served with presigned URLs.
  media_env = var.enable_media_bucket ? merge(
    { MEDIA_BUCKET = module.media[0].bucket_name },
    var.media_cdn ? { MEDIA_URL = module.media[0].media_url } : {},
  ) : {}

  # rediss://host:6379/0 carries no credentials (the security group is the
  # auth boundary), so it is fine as a plain environment variable.
  cache_env = var.enable_cache ? { REDIS_URL = module.cache[0].redis_url } : {}

  app_env = merge(local.base_env, local.media_env, local.cache_env, var.plain_env)

  # Worker sizing defaults to the web task's values (null -> same as web).
  worker_cpu               = coalesce(var.worker_cpu, var.cpu)
  worker_memory            = coalesce(var.worker_memory, var.memory)
  worker_capacity_provider = coalesce(var.worker_capacity_provider, var.capacity_provider)

  # Security groups that may reach the database and the cache: the app tasks,
  # plus the migration host while it exists. The modules index these with
  # count, so order matters only in that new entries go at the end.
  data_client_security_group_ids = concat(
    [module.web.security_group_id],
    var.enable_worker ? [module.worker[0].security_group_id] : [],
    var.enable_migration_host ? [module.migration_host[0].security_group_id] : [],
  )

  # "18" -> 18, "17.6" -> 17: the client tools on the migration host must match
  # the target major (the shared instance's actual version when shared_database).
  db_major                = tonumber(split(".", local.db_engine_version)[0])
  migration_host_pg_major = coalesce(var.migration_host_pg_major, local.db_major)

  # Task definition family for one-off tooling runs (migrations.tf) and the
  # family ARN pattern the deploy role may RunTask (every revision).
  tools_family     = "${local.name}-tools"
  tools_family_arn = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:task-definition/${local.tools_family}:*"

  # Bootstrap's naming convention for the state bucket; must match backend.tf.
  state_bucket     = "tfstate-${local.account_id}-${local.region}"
  state_key_prefix = "${var.project}/${var.environment}"
}
