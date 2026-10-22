# ecs_service

One container image running as an ECS service on Fargate. Used twice per project: once for the web
service (`expose_http = true`, attached to the ALB) and optionally once for a worker
(`expose_http = false`, `create_ecr_repository = false`, `image = module.web.image`).

Read `main.tf` top to bottom: the container definition is a plain `jsonencode([...])` block so you can
see exactly what ECS receives.

## What it creates

| Resource | Purpose |
|---|---|
| `aws_ecr_repository` + lifecycle policy (optional) | Repo named `<name>`, scan on push, keep 20 images, expire untagged after 7 days |
| `aws_cloudwatch_log_group` | `/ecs/<name>` with retention |
| `aws_iam_role` execution | `AmazonECSTaskExecutionRolePolicy` + `secretsmanager:GetSecretValue` on `secret_arns` (+ `kms:Decrypt`) |
| `aws_iam_role` task | What your code may call: ECS Exec channels when enabled + your `task_policy_json` |
| `aws_security_group` | Ingress `container_port` from the ALB SG only (web); all egress |
| `aws_ecs_task_definition` | Fargate, awsvpc, ARM64 by default, awslogs non-blocking, init process, container health check (web) |
| `aws_lb_target_group` + `aws_lb_listener_rule` (web) | IP targets, health check on `health_check_path` (200-399), host-header rule on the shared :443 listener |
| `aws_ecs_service` | Capacity-provider strategy, rolling deploy, circuit breaker with rollback, managed tags, `ignore_changes = [desired_count]` |
| `aws_appautoscaling_target` + policies | CPU target tracking; optional `ALBRequestCountPerTarget` |
| `aws_cloudwatch_metric_alarm` (optional) | target 5xx, unhealthy hosts (web only), service CPU > 85 %, memory > 85 % |

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Full service name, e.g. `acme-prod-web` |
| `cluster_arn` | string | required | ECS cluster ARN (must have FARGATE + FARGATE_SPOT capacity providers associated) |
| `cluster_name` | string | required | ECS cluster name |
| `vpc_id` | string | required | VPC for SG and target group |
| `subnet_ids` | list(string) | required | Task subnets |
| `assign_public_ip` | bool | `true` | Public IPv4 per task (~$3.65/mo each); required in public subnets without NAT |
| `create_ecr_repository` | bool | `true` | Create the ECR repo and run `<repo>:<image_tag>` |
| `image_tag` | string | `"bootstrap"` | Tag to run from the module repo |
| `image` | string | `null` | Full image reference when `create_ecr_repository = false` |
| `ecr_force_delete` | bool | `false` | Let destroy delete a non-empty repo |
| `container_name` | string | `"app"` | Container name inside the task |
| `container_port` | number | `3000` | App port |
| `cpu` | number | `512` | Task CPU units |
| `memory` | number | `1024` | Task memory (MiB); must pair with `cpu` |
| `cpu_architecture` | string | `"ARM64"` | `ARM64` or `X86_64` |
| `ephemeral_storage_gib` | number | `null` | 21-200 GiB; null = free 20 GiB |
| `container_command` | list(string) | `null` | Override image CMD |
| `environment` | map(string) | `{}` | Plain env vars (visible in state) |
| `secrets` | list(object) | `[]` | `[{ name, valueFrom }]` from the secrets module |
| `secret_arns` | list(string) | `[]` | Secret ARNs the execution role may read |
| `kms_key_arn` | string | `null` | CMK for secrets/logs/ECR |
| `stop_timeout` | number | `30` | SIGTERM -> SIGKILL seconds (max 120) |
| `linux_init_process` | bool | `true` | tini as PID 1 |
| `enable_execute_command` | bool | `false` | ECS Exec shells |
| `task_policy_json` | string | `null` | Extra IAM policy for the task role |
| `expose_http` | bool | `true` | Attach to the ALB |
| `https_listener_arn` | string | `null` | ALB :443 listener (required when exposed) |
| `alb_security_group_id` | string | `null` | ALB SG (required when exposed) |
| `host_headers` | list(string) | `[]` | Hostnames routed to this service (required when exposed) |
| `listener_rule_priority` | number | `100` | Unique per listener |
| `health_check_path` | string | `"/api/health"` | ALB and container health check path |
| `health_check_grace_period_seconds` | number | `60` | Grace after task start; also container `startPeriod` |
| `enable_container_health_check` | bool | `true` | Docker-level health check in the task definition |
| `container_health_check_command` | list(string) | `null` | Override the built-in wget -> curl -> node chain |
| `desired_count` | number | `1` | Initial task count (then owned by autoscaling) |
| `min_capacity` | number | `1` | Autoscaling floor |
| `max_capacity` | number | `2` | Autoscaling ceiling (= cost ceiling) |
| `autoscaling_target_cpu` | number | `70` | CPU target % |
| `autoscaling_target_requests_per_target` | number | `null` | Optional requests/target/minute policy |
| `capacity_provider` | string | `"FARGATE"` | `FARGATE` or `FARGATE_SPOT` |
| `deployment_minimum_healthy_percent` | number | `100` | Keep old tasks until new are healthy |
| `deployment_maximum_percent` | number | `200` | Allow one extra set during rollout |
| `deployment_alarm_rollback` | bool | `false` | Roll back on the 5xx alarm too (adds ~10 min bake) |
| `log_retention_days` | number | `30` | Log group retention |
| `alarm_topic_arn` | string | `null` | SNS topic; null = no alarms |

## Outputs

| Name | Description |
|---|---|
| `service_name`, `service_arn` | ECS service |
| `task_definition_arn`, `task_family` | Registered task definition (`family:revision`) and family |
| `container_name` | For `scheduled_task.container_name` and `aws ecs execute-command --container` |
| `image` | Full image reference (feed to a worker instance) |
| `ecr_repository_url`, `ecr_repository_arn` | Module-created repo, or `null` |
| `security_group_id` | Task SG (allow it in the RDS SG) |
| `task_role_arn`, `execution_role_arn` | For `scheduled_task` and the GitHub deploy role's `iam:PassRole` |
| `log_group_name` | `/ecs/<name>` |
| `log_group_arn` | ARN of that log group (IAM scoping for log readers). |
| `target_group_arn` | ALB target group or `null` |

## Cost (us-east-1, Oct 2026, 730 h)

| Task size (ARM64) | Per always-on task |
|---|---|
| 0.25 vCPU / 0.5 GB | ~$7.21 |
| 0.25 vCPU / 1 GB | ~$8.51 |
| 0.5 vCPU / 1 GB (default) | ~$14.42 |
| 1 vCPU / 2 GB | ~$28.83 |

Plus per task: ~$3.65/mo for its public IPv4 (`assign_public_ip = true`), ~$0.11/GB-month for
ephemeral storage above 20 GiB. x86_64 is ~25 % more than ARM64. `FARGATE_SPOT` is up to 70 % less.
Logs: $0.50/GB ingested, 5 GB/month free. ECR: $0.10/GB-month. Alarms: 10 free per account.
During a deploy you briefly pay for `deployment_maximum_percent` worth of tasks.

**Worst-case monthly compute = `max_capacity` x task price.** Set it deliberately.

## First deploy: the empty-repository problem

On the very first `terraform apply` the ECR repository exists but contains no image, so the service's
first deployment fails to pull `<repo>:bootstrap`, the circuit breaker marks it FAILED, and the service
sits at 0 running tasks. That is expected and harmless. Either:

1. apply once, build and push your image tagged with the SHA, then `terraform apply -var image_tag=<sha>`
   (Terraform owns the tag; every release is a plan), or
2. push an image tagged `bootstrap` before the first apply.

The task's `secrets` must also exist with values (`scripts/put_secrets.sh`) before a task can start;
a missing JSON key fails the task with `ResourceInitializationError`.

## Gotchas

- **Capacity providers must be associated with the cluster.** The root must create
  `aws_ecs_cluster_capacity_providers` with `["FARGATE", "FARGATE_SPOT"]`, or service creation fails
  with "capacity provider strategy is invalid".
- **ARM64 images.** `cpu_architecture = "ARM64"` means the image must be built for `linux/arm64`
  (`docker buildx build --platform linux/arm64`). A wrong-arch image fails with `exec format error`
  in the logs and the circuit breaker rolls back.
- **cpu/memory pairs are fixed by Fargate.** 256 -> 512/1024/2048; 512 -> 1024-4096; 1024 -> 2048-8192;
  2048 -> 4096-16384; 4096 -> 8192-30720. Other combinations fail at task-definition registration.
- **The health check path must be cheap and self-contained.** It runs every 15 s from the ALB and every
  30 s inside the container. Do not touch the database in it, or a DB blip becomes a full restart loop.
- **`node:*-slim` images have no wget/curl.** The built-in container health check falls through to
  `node -e "fetch(...)"`, which needs Node 18+. Non-Node images: pass `container_health_check_command`
  or set `enable_container_health_check = false` and rely on the ALB check alone.
- **Secrets are read once, at task start.** After rotating a secret value run
  `aws ecs update-service --force-new-deployment`.
- **`desired_count` drift is intentional** (`ignore_changes`). Change `min_capacity`/`max_capacity`
  to resize; changing `desired_count` after the first apply does nothing.
- **Changing `container_port` replaces the target group.** The target group name is static, so
  Terraform must delete the old one first; expect a short outage, or rename the service.
- **Fargate Spot** can be reclaimed with 2 minutes notice (SIGTERM, then `stop_timeout`). Fine for
  idempotent workers, wrong for a `min_capacity = 1` web service.
- **ECS Exec runs as root and needs `linux_init_process = true`**; it is incompatible with a read-only
  root filesystem. Operator command:
  `aws ecs execute-command --cluster <cluster> --task <task-id> --container app --interactive --command /bin/sh`.
- **Public IPs are safe here** because the SG only admits the ALB on `container_port`; the IP is only
  for outbound. Moving to private subnets means adding a NAT gateway (~$33/mo) or VPC endpoints.
- **Egress is wide open** (`0.0.0.0/0`). Restrict to 443 + 5432 once you know what the app talks to.
- **`kms_key_arn` also encrypts the log group and ECR repo.** The key policy must allow
  `logs.<region>.amazonaws.com` to use the key (`kms:Encrypt*`, `kms:Decrypt*`, `kms:GenerateDataKey*`,
  `kms:Describe*` with an `kms:EncryptionContext:aws:logs:arn` condition), or log group creation fails.
- **Alarm-based rollback (`deployment_alarm_rollback`)** adds a bake window equal to the alarm's
  evaluation period (2 x 5 min), so `aws ecs wait services-stable` takes ~10 minutes longer.
