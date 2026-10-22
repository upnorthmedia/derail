# ecs_service: one container image running as an ECS service on Fargate, with
# an ECR repository, log group, IAM roles, security group, optional ALB
# attachment, autoscaling and alarms. The same module serves a web service
# (expose_http = true) and a worker (expose_http = false).
#
# Cost (us-east-1, Oct 2026, 730 h/mo, ARM64): 0.25 vCPU/0.5 GB ~$7.21,
# 0.25/1 GB ~$8.51, 0.5/1 GB ~$14.42, 1/2 GB ~$28.83 per always-on task; x86 is
# ~25% more. Add ~$3.65/mo per task for its public IPv4 when assign_public_ip.
# Fargate Spot is up to 70% cheaper but can be reclaimed with 2 minutes notice.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  image = var.create_ecr_repository ? "${aws_ecr_repository.this[0].repository_url}:${var.image_tag}" : var.image

  # Target group names are capped at 32 characters.
  target_group_name = "${trimsuffix(substr(var.name, 0, 29), "-")}-tg"

  # The ALB's arn_suffix ("app/<name>/<id>") is embedded in the listener ARN
  # ("...:listener/app/<name>/<id>/<listener-id>"). Deriving it here saves the
  # root from passing one more value; it is used for CloudWatch dimensions and
  # the ALBRequestCountPerTarget resource label.
  alb_arn_suffix = try(join("/", slice(split("/", var.https_listener_arn), 1, 4)), null)

  # Container health check: tries wget (busybox/alpine), then curl, then Node's
  # built-in fetch (node:*-slim images ship neither wget nor curl). Any tool
  # that is missing just falls through to the next one.
  health_url = "http://127.0.0.1:${var.container_port}${var.health_check_path}"
  default_health_check_command = [
    "CMD-SHELL",
    "wget -qO- ${local.health_url} >/dev/null 2>&1 || curl -fsS ${local.health_url} >/dev/null 2>&1 || node -e \"fetch('${local.health_url}').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\" || exit 1",
  ]
  health_check_command = var.expose_http && var.enable_container_health_check ? coalesce(var.container_health_check_command, local.default_health_check_command) : null

  # Sorted so the task definition JSON (and therefore the plan diff) is stable.
  secrets_by_name = { for s in var.secrets : s.name => s.valueFrom }
}

# ---------------------------------------------------------------------------
# Image registry
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "this" {
  count = var.create_ecr_repository ? 1 : 0

  name = var.name
  # MUTABLE so CI can re-point a moving tag (e.g. "main", "latest") and so a
  # retagged rollback is possible. IMMUTABLE is stricter but breaks every
  # workflow that pushes the same tag twice; switch once you deploy by SHA only.
  image_tag_mutability = "MUTABLE"
  force_delete         = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = true # basic scanning is free
  }

  encryption_configuration {
    encryption_type = var.kms_key_arn == null ? "AES256" : "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = { Name = var.name }
}

# ECR storage is $0.10/GB-month; a Next.js image is 150-400 MB, so 20 tagged
# images is a few dollars. Untagged layers are leftovers from re-pushed tags.
resource "aws_ecr_lifecycle_policy" "this" {
  count = var.create_ecr_repository ? 1 : 0

  repository = aws_ecr_repository.this[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the 20 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = { Name = "/ecs/${var.name}" }
}

# ---------------------------------------------------------------------------
# Security group: nothing in, everything out
# ---------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name        = "${var.name}-tasks"
  description = "ECS tasks for ${var.name}"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-tasks" }

  lifecycle {
    create_before_destroy = true
  }
}

# Only the ALB may talk to the container port. Even with a public IP on the
# task, nobody else can reach it.
resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  count = var.expose_http ? 1 : 0

  security_group_id            = aws_security_group.this.id
  description                  = "App port from the ALB"
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = var.alb_security_group_id
}

# Outbound is open: the task must reach ECR, CloudWatch, Secrets Manager, the
# database and third-party APIs. Tighten to 443 + 5432 once you know the app.
resource "aws_vpc_security_group_egress_rule" "all_ipv4" {
  security_group_id = aws_security_group.this.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all_ipv6" {
  security_group_id = aws_security_group.this.id
  description       = "All outbound"
  cidr_ipv6         = "::/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Task definition: the container spec, readable as JSON below
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # the only mode on Fargate: each task gets its own ENI
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  # 20 GiB is included; only declare the block when asking for more (extra GiB bill ~$0.11/GB-month).
  dynamic "ephemeral_storage" {
    for_each = var.ephemeral_storage_gib == null ? [] : [var.ephemeral_storage_gib]
    content {
      size_in_gib = ephemeral_storage.value
    }
  }

  container_definitions = jsonencode([
    merge(
      {
        name      = var.container_name
        image     = local.image
        essential = true

        portMappings = [
          {
            containerPort = var.container_port
            protocol      = "tcp"
          }
        ]

        # Plain config. Visible to anyone who can describe the task definition.
        environment = [
          for k in sort(keys(var.environment)) : { name = k, value = var.environment[k] }
        ]

        # Secrets are resolved by the ECS agent at task start using the
        # EXECUTION role; the container only ever sees ordinary env vars.
        secrets = [
          for k in sort(keys(local.secrets_by_name)) : { name = k, valueFrom = local.secrets_by_name[k] }
        ]

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.this.name
            awslogs-region        = data.aws_region.current.region
            awslogs-stream-prefix = var.container_name
            # non-blocking: if CloudWatch is slow the app keeps running and
            # the oldest buffered lines are dropped, instead of stdout blocking.
            mode            = "non-blocking"
            max-buffer-size = "25m"
          }
        }

        linuxParameters = {
          initProcessEnabled = var.linux_init_process
        }

        # Seconds between SIGTERM and SIGKILL on stop/deploy.
        stopTimeout = var.stop_timeout

        # false because Next.js writes its ISR/image cache under .next/ and
        # ECS Exec is not supported with a read-only root. Flip to true for
        # apps that write only to /tmp (then add a tmpfs mount).
        readonlyRootFilesystem = false
      },
      # Optional pieces, only present when configured.
      var.container_command == null ? {} : { command = var.container_command },
      local.health_check_command == null ? {} : {
        healthCheck = {
          command     = local.health_check_command
          interval    = 30
          timeout     = 5
          retries     = 3
          startPeriod = var.health_check_grace_period_seconds
        }
      },
    )
  ])

  tags = { Name = var.name }
}

# ---------------------------------------------------------------------------
# ALB attachment (web services only)
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "this" {
  count = var.expose_http ? 1 : 0

  name        = local.target_group_name
  vpc_id      = var.vpc_id
  target_type = "ip" # required for Fargate (awsvpc) tasks
  port        = var.container_port
  protocol    = "HTTP"

  # 30 s instead of the 300 s default: a single-task deploy would otherwise
  # keep the old task "draining" for five minutes.
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200-399"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = local.target_group_name }
}

resource "aws_lb_listener_rule" "this" {
  count = var.expose_http ? 1 : 0

  listener_arn = var.https_listener_arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }

  condition {
    host_header {
      values = var.host_headers
    }
  }

  tags = { Name = "${var.name}-rule" }
}

# ---------------------------------------------------------------------------
# The service
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count

  # capacity_provider_strategy (not launch_type) so FARGATE_SPOT is a one-word
  # switch. The cluster must have both providers associated.
  capacity_provider_strategy {
    capacity_provider = var.capacity_provider
    weight            = 1
    base              = 0
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.this.id]
    assign_public_ip = var.assign_public_ip
  }

  dynamic "load_balancer" {
    for_each = var.expose_http ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.this[0].arn
      container_name   = var.container_name
      container_port   = var.container_port
    }
  }

  # Rolling deploy: start the new task, wait until it is healthy, then stop
  # the old one. With desired_count = 1 this is still zero-downtime.
  deployment_controller {
    type = "ECS"
  }
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent

  # A deployment whose tasks keep crashing or failing health checks is marked
  # FAILED and the service rolls back to the last good task definition,
  # instead of looping forever.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Optional: also roll back when the 5xx alarm fires during the bake window.
  dynamic "alarms" {
    for_each = var.deployment_alarm_rollback && var.expose_http && var.alarm_topic_arn != null ? [1] : []
    content {
      alarm_names = [aws_cloudwatch_metric_alarm.target_5xx[0].alarm_name]
      enable      = true
      rollback    = true
    }
  }

  # Ignore failing ALB health checks for this long after a task starts.
  health_check_grace_period_seconds = var.expose_http ? var.health_check_grace_period_seconds : null

  enable_execute_command = var.enable_execute_command

  # Tasks inherit the service tags (and therefore the provider default_tags),
  # which is what makes Fargate spend show up per Project in Cost Explorer.
  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  # Do not block terraform apply on the rollout; CI watches the deployment
  # with `aws ecs wait services-stable` where that matters.
  wait_for_steady_state = false

  tags = { Name = var.name }

  lifecycle {
    # Autoscaling changes desired_count at runtime; Terraform must not fight it.
    ignore_changes = [desired_count]
  }

  # The target group must be attached to a listener before ECS accepts it.
  depends_on = [aws_lb_listener_rule.this]
}

# ---------------------------------------------------------------------------
# Autoscaling: target tracking on CPU, optionally on requests per target
# ---------------------------------------------------------------------------

resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.autoscaling_target_cpu
    scale_in_cooldown  = 300 # slow to remove capacity
    scale_out_cooldown = 60  # quick to add it
  }
}

resource "aws_appautoscaling_policy" "requests" {
  count = var.expose_http && var.autoscaling_target_requests_per_target != null ? 1 : 0

  name               = "${var.name}-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      # Format: app/<alb-name>/<alb-id>/targetgroup/<tg-name>/<tg-id>
      resource_label = "${local.alb_arn_suffix}/${aws_lb_target_group.this[0].arn_suffix}"
    }
    target_value       = var.autoscaling_target_requests_per_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
