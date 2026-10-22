# scheduled_task

Railway "cron schedule" equivalent: an EventBridge Scheduler schedule that runs `ecs:RunTask` on your
existing task definition with the container command replaced. Same image, same env vars and secrets,
same network as the app; no container running between invocations.

Typical root usage (one instance per entry in `var.cron_jobs`):

```hcl
module "cron" {
  source   = "../../modules/scheduled_task"
  for_each = var.cron_jobs # map of { schedule = string, command = list(string) }

  name                = "${local.name}-${each.key}"
  schedule_expression = each.value.schedule
  command             = each.value.command

  cluster_arn         = aws_ecs_cluster.this.arn
  task_definition_arn = module.web.task_definition_arn
  task_role_arn       = module.web.task_role_arn
  execution_role_arn  = module.web.execution_role_arn
  container_name      = module.web.container_name
  subnet_ids          = local.task_subnet_ids
  security_group_ids  = [module.web.security_group_id]
  assign_public_ip    = var.task_in_public_subnets
}
```

## What it creates

| Resource | Purpose |
|---|---|
| `aws_iam_role` + inline policy | Trusts `scheduler.amazonaws.com` (scoped to this account and this schedule's ARN); allows `ecs:RunTask` on the task definition *family* (`...:family:*`, any revision) only in your cluster, `ecs:TagResource` for RunTask, and `iam:PassRole` on the task + execution roles only to `ecs-tasks.amazonaws.com` |
| `aws_scheduler_schedule` | `ecs_parameters` templated target: capacity-provider strategy, awsvpc network config, `task_count = 1`, managed tags propagated from the task definition; `input` carries `containerOverrides[].command`; retry policy |

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Schedule / role name, e.g. `acme-prod-cleanup` |
| `schedule_expression` | string | required | `rate(1 hour)`, 6-field `cron(0 5 * * ? *)`, or `at(...)` |
| `schedule_timezone` | string | `"UTC"` | IANA zone for cron evaluation |
| `cluster_arn` | string | required | ECS cluster |
| `task_definition_arn` | string | required | Task definition to run (`family:revision`) |
| `task_role_arn` | string | required | Its task role (PassRole) |
| `execution_role_arn` | string | required | Its execution role (PassRole) |
| `subnet_ids` | list(string) | required | 1-16 subnets |
| `security_group_ids` | list(string) | required | 1-5 security groups |
| `assign_public_ip` | bool | `true` | Needed in public subnets without NAT |
| `container_name` | string | required | Container whose command is overridden |
| `command` | list(string) | required | argv to run |
| `capacity_provider` | string | `"FARGATE_SPOT"` | `FARGATE_SPOT` or `FARGATE` |
| `flexible_time_window_minutes` | number | `0` | 0 = exact; 1-1440 = run within that window |
| `retry_attempts` | number | `1` | RunTask API retries (0-185) |
| `maximum_event_age_in_seconds` | number | `3600` | Stop retrying after this long (60-86400) |
| `enabled` | bool | `true` | `false` pauses the schedule |
| `description` | string | `null` | Console description |

## Outputs

| Name | Description |
|---|---|
| `schedule_arn` | Schedule ARN |
| `schedule_name` | Schedule name |
| `scheduler_role_arn` | Role Scheduler assumes |

## Cost

- Scheduler: free for the first 14 million invocations per month, then $1.00 per million.
- The task: ordinary Fargate per-second pricing with a 1-minute minimum, on Spot by default (up to
  70 % off on-demand). A 0.5 vCPU / 1 GB ARM64 task costs about $0.02 per hour on-demand, so a
  2-minute nightly job is well under $0.10/month.
- Public IPv4: $0.005/hour only while the task runs.

## Differences from Railway cron (read before migrating)

- **Six-field cron.** Scheduler cron is `cron(minutes hours day-of-month month day-of-week year)`.
  Railway's `0 5 * * *` becomes `cron(0 5 * * ? *)`. One of day-of-month / day-of-week must be `?`.
  `rate(...)` is simpler for "every N minutes/hours".
- **No overlap protection.** Railway skips a run if the previous one is still going; Scheduler
  starts a new task every time. If a job can take longer than its interval, make it idempotent and
  guard it (a Postgres advisory lock, `SELECT ... FOR UPDATE SKIP LOCKED`, or a "last run" row).
- **Retries are not re-runs.** `retry_attempts` retries the *RunTask API call* when ECS cannot start
  the task (no Spot capacity, throttling, ENI limits). A task that started and exited non-zero is not
  retried; put that logic in the job or watch the task's exit code (EventBridge `ECS Task State Change`
  events with `stopCode`/`exitCode`, or a CloudWatch Logs metric filter on your error line).
- **Time zone is explicit.** `schedule_timezone = "America/Chicago"` makes `cron(0 5 ...)` fire at
  05:00 local across DST changes.
- **The job runs the web image.** Whatever `command` you pass must exist in that image (`node scripts/x.js`,
  `npx prisma migrate deploy`). Build-time-only tools stripped from a production image are not available.

## Gotchas

- **The schedule pins a task definition revision.** Because Terraform passes `module.web.task_definition_arn`
  (`family:revision`), every `terraform apply` that registers a new revision updates the schedule
  too, which is what you want. If you deploy new revisions from CI outside Terraform, the schedule
  keeps running the Terraform-known revision until the next apply.
- **Spot has no fallback.** With `capacity_provider = "FARGATE_SPOT"` and no Spot capacity, RunTask
  fails and Scheduler retries up to `retry_attempts` within `maximum_event_age_in_seconds`. For jobs
  that must run (billing, invoices), use `FARGATE`.
- **Role trust is scoped to this schedule's ARN** in the `default` schedule group. Renaming the
  schedule or moving it to another group changes the ARN; Terraform updates both together.
- **Logs** land in the service's log group (`/ecs/<service>`) under the same stream prefix, because
  the task definition is shared. Filter by task ID or make the job print a distinctive first line.
- **Secrets** are resolved at task start exactly like the service, so a rotated secret reaches the
  next cron run automatically, unlike the long-running service that needs a new deployment.
- **A failed `ecs:RunTask` is silent** unless you look. The schedule's CloudWatch metrics
  (`AWS/Scheduler` `InvocationAttemptCount`, `TargetErrorCount`) are free; an alarm on
  `TargetErrorCount >= 1` is a cheap safety net once the schedule matters.
