# One-off tooling task definition: "<project>-<env>-tools".
#
# Database migrations (and any other one-shot command: seeds, backfills,
# `rails console`-style scripts) must run with the SAME roles, secrets,
# environment and network placement as the web task, but from an image that
# still contains the migration CLI and dev dependencies the production image
# strips out. So this is the web task definition copied verbatim with two
# differences: the image tag carries tools_image_tag_suffix, and the default
# command is migration_command. The deploy workflow registers nothing itself;
# it runs `aws ecs run-task` on this family (latest ACTIVE revision), waits,
# and streams the log stream back. Output migration_run_task carries every
# value it needs.
#
# Why not a module: it is one resource and reading the JSON here, next to the
# web module call, is clearer than another layer of inputs.

resource "aws_ecs_task_definition" "tools" {
  count = var.enable_migration_task ? 1 : 0

  family                   = local.tools_family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = module.web.execution_role_arn # pulls the image, reads the same secret
  task_role_arn            = module.web.task_role_arn      # same S3/SSM rights as the app

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64" # the tools stage is built for linux/arm64 like the web image
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = "${module.web.ecr_repository_url}:${var.image_tag}${var.tools_image_tag_suffix}"
      essential = true
      command   = var.migration_command

      # Same plain config and the same Secrets Manager references as the web
      # task, so DATABASE_URL etc. resolve identically, with one deliberate
      # difference: when the app secret also holds DATABASE_MIGRATE_URL (the
      # app_migrate/owner role from scripts/sql/app_roles.sql.tpl), the migration
      # container sees THAT value as DATABASE_URL. Migrations then run with DDL
      # rights while the web/worker tasks keep the DML-only app_rw role, and the
      # ORM needs no special configuration.
      environment = [
        for k in sort(keys(local.app_env)) : { name = k, value = local.app_env[k] }
      ]
      secrets = concat(
        [
          for s in module.secrets.ecs_secrets : s
          if s.name != "DATABASE_MIGRATE_URL" && !(s.name == "DATABASE_URL" && local.has_migrate_url)
        ],
        local.has_migrate_url ? [{
          name      = "DATABASE_URL"
          valueFrom = "${module.secrets.app_secret_arn}:DATABASE_MIGRATE_URL::"
        }] : []
      )

      # Same log group as the web service; the stream prefix equals the
      # container name, so a run's stream is "<container>/<container>/<task id>".
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = module.web.log_group_name
          awslogs-region        = local.region
          awslogs-stream-prefix = local.container_name
          mode                  = "non-blocking"
          max-buffer-size       = "25m"
        }
      }

      linuxParameters = {
        initProcessEnabled = true
      }

      # Give a long-running migration time to finish its transaction on stop.
      stopTimeout = 120

      readonlyRootFilesystem = false
    }
  ])

  tags = { Name = local.tools_family }
}
