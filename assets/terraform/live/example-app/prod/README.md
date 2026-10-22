# live/example-app/prod

The per-project, per-environment root. Copy this directory to
`live/<project>/<environment>/`, edit `backend.tf` (bucket, key) and
`terraform.tfvars`, and apply. Everything the project needs lives in this one
state file; nothing here touches another project's resources.

## What it builds

```
Route 53 (hosted_zone_name; created here with create_hosted_zone, or looked up)
  app.example.com   -> [CloudFront (optional, + WAF)] -> ALB (HTTPS, ACM) -> ECS Fargate "web"
  www.example.com   -> 301 to app.example.com     (additional_domain_names; CloudFront Function or ALB rule)
  origin.app.example.com -> ALB                   (only when CloudFront is on; never user-facing)
  cdn.example.com   -> CloudFront -> S3 media bucket   (optional; media_cdn = false = private bucket only)
  <old platform records>, MX/TXT/...              (old_platform_records while traffic_target = "old"; extra_dns_records always)

ECS cluster <project>-<env>            (or the shared platform cluster, shared_cluster)
  web      service   (ARM64 Fargate, autoscaled, ECR repo <project>-<env>-web)
  worker   service   (optional, same image, worker_command, own sizing)
  cron     schedules (optional, EventBridge Scheduler -> RunTask, same image; PAUSED until crons_enabled)
  tools    task definition <project>-<env>-tools (migrations.tf: web task + tools image + migration_command)

RDS PostgreSQL <project>-<env>-db      (private subnets, SG from web/worker/migration host only;
                                        or a database inside the shared instance, shared_database)
ALB <project>-<env>-alb                (or own certificate + rules on the shared ALB, shared_alb)
ElastiCache Valkey <project>-<env>-cache (optional, enable_cache; REDIS_URL injected)
Migration host (optional, enable_migration_host: SSM-only EC2 for pg_dump/pg_restore)
Secrets Manager <project>-<env>/app    (one JSON secret, values written out-of-band)
SNS <project>-<env>-alerts, monthly budget, cost anomaly monitor
IAM roles for GitHub Actions: -github-plan, -github-apply, -github-deploy
```

Shared with other projects (created once per account): the VPC/subnets from
`network/`, the state bucket and OIDC provider from `bootstrap/`, and
optionally the cluster, ALB and RDS instance from `platform/` (see "Shared
platform mode"). This root discovers the VPC by tag (`Name = <platform_name>-vpc`,
`Tier = public|private`), the OIDC provider by URL and the platform pieces by
name/tag; there is no remote-state coupling.

Files: `main.tf` (composition), `dns.tf` (zone, old-platform records, cutover
switch, www redirect), `shared.tf` (certificate on the shared ALB, ingress
rules on the shared database), `migrations.tf` (tools task definition),
`locals.tf` (environment per `framework`, sizing defaults, shared/dedicated
indirection), `data.tf`, `variables.tf`, `outputs.tf`.

## Shared platform mode (agencies, many small sites)

Three flags, all default `false`, swap the expensive fixed-cost pieces for
the ones the `platform/` root created once per account:

| Flag | Instead of | This root still creates | Saves |
|---|---|---|---|
| `shared_cluster` | cluster `<project>-<env>` | the services, task definitions, roles | nothing (clusters are free); less console noise |
| `shared_alb` | ALB `<project>-<env>-alb` + certificate | its **own ACM certificate** attached to the shared :443 listener by SNI, host-header rules at `listener_rule_priority` (web) and `+ 1` (www redirect), Route 53 aliases to the shared ALB | ~$25/month |
| `shared_database` | RDS `<project>-<env>-db` | ingress rules on the shared instance's SG from the web / worker / migration-host SGs; outputs `db_endpoint`, `db_port`, `db_name` (= `shared_db_name`), `db_master_secret_arn` (the **platform** master secret) | ~$12-23/month |

Lookups (`data.tf`): cluster by name `<platform_name>`, ALB by tags
`Name = <platform_name>-alb` + `Shared = "true"` (the root asserts it has
exactly one security group, which the task SGs then trust), listener by
`port = 443`, instance by identifier `<platform_name>-db`, its SG by tag
`Name = <platform_name>-db` (asserted to be attached to that instance).
`locals.tf` hides the difference (`local.cluster_*`, `local.https_listener_arn`,
`local.alb_*`, `local.db_*`), so the rest of the root does not care.

What changes in the runbook:

- **`listener_rule_priority` must be unique per project on the shared ALB**
  (default `100` is reserved for dedicated ALBs; take the next free pair from
  the table in `platform/README.md`). Collisions fail at apply with
  `PriorityInUse`.
- **The project's database and roles are created out-of-band**, exactly like
  the app secret values: Terraform only wires networking and outputs. From the
  migration host (it can read the platform master secret) or any host in the
  VPC, with `TGT_URL` pointing at the shared instance's `postgres` database as
  the master user:

  ```sh
  APP_RW_PASSWORD=... APP_MIGRATE_PASSWORD=... \
    scripts/pg_migrate.sh roles --target-db $(terraform output -raw db_name) \
      --app-owner example_app_owner --app-rw example_app_rw --app-migrate example_app_migrate
  ```

  `roles` creates the database if missing (`restore --target-db ... --role
  example_app_owner` does too). Role names are cluster-wide: prefix them with
  the project. `DATABASE_URL` in the app secret then uses the `_rw` role and
  `<db_endpoint>:5432/<db_name>`; the master user is never used by the app.
- `db_instance_class`, `db_engine_version`, `db_allocated_storage` and
  `db_multi_az` are ignored; the migration host's PostgreSQL client major is
  taken from the shared instance's actual version.
- Cheapest sane web config on the shared platform: `cpu = 256`, `memory = 512`,
  `capacity_provider = "FARGATE_SPOT"` (~$2-3/month compute; Spot tasks can be
  reclaimed with 2 minutes notice, which with one task is a brief outage).
  Keep the app's connection pool small (5 per task); the shared instance's
  `max_connections` (~190 on `db.t4g.small`) is split between every tenant.
- Decommissioning the project (`make destroy`) removes its certificate, rules
  and ingress rules and leaves the platform alone; drop the database and roles
  by hand afterwards.

Read the blast-radius section of `platform/README.md` before opting in; one
instance means one maintenance window and one failover for every tenant.

## Prerequisites

1. `bootstrap/` and `network/` applied in this account and region (and
   `platform/` if any `shared_*` flag is true).
2. A public Route 53 hosted zone for `hosted_zone_name`: either existing
   (`create_hosted_zone = false`) or created by this root
   (`create_hosted_zone = true`, then delegate at the registrar; see
   "DNS: delegate early, cut over late"). **ACM certificates only issue once
   the zone is authoritative**, because the validation CNAMEs are written to
   Route 53. Until then `aws_acm_certificate_validation` waits and finally
   times out (~75 min). Workaround if you cannot delegate yet: copy the
   validation CNAMEs (`aws acm describe-certificate`) into the old DNS provider
   by hand; ACM accepts them from anywhere.
3. AWS credentials with admin-ish rights for the *first* apply
   (`aws login` / SSO). Afterwards CI uses the generated roles.
4. Terraform >= 1.11 or OpenTofu >= 1.11, tflint, and (optional) trivy.

## First apply, step by step

```sh
cd live/example-app/prod
cp terraform.tfvars.example terraform.tfvars   # edit values
# edit backend.tf: bucket = tfstate-<account id>-<region>, key = <project>/<env>/terraform.tfstate

make init ROOT=live/example-app/prod
make plan ROOT=live/example-app/prod
make apply ROOT=live/example-app/prod
```

The first apply runs with `image_tag = "bootstrap"`, which does not exist in
ECR yet, so the ECS service is created but its tasks fail to pull. That is
expected. Then:

1. **Write the secrets** (values never pass through Terraform):
   `scripts/put_secrets.sh $(terraform output -raw app_secret_name)` prompts for
   each key in `secret_keys`. `DATABASE_URL` is
   `postgresql://<user>:<pw>@$(terraform output -raw db_endpoint):5432/$(terraform output -raw db_name)?sslmode=require`
   where the password comes from `aws secretsmanager get-secret-value --secret-id $(terraform output -raw db_master_secret_arn)`
   (prefer a dedicated app role; see the rds_postgres README; with
   `shared_database = true` the app role is mandatory and the database must be
   created first, see "Shared platform mode"). `REDIS_URL` is injected
   automatically when `enable_cache = true`; it is not a secret.
2. **Set the GitHub repository variables** from the outputs:
   `TF_PLAN_ROLE_ARN`, `TF_APPLY_ROLE_ARN`, `DEPLOY_ROLE_ARN`, `AWS_REGION`,
   `TF_ROOT=infra/live/example-app/prod`, `ECR_REPOSITORY` (from
   `ecr_repository_url`, the part after the `/`).
3. **Check `github_environment`.** It defaults to `"prod"` and MUST equal the
   `environment:` of the apply job in `.github/workflows/terraform.yml`. With a
   mismatch the OIDC subject (`repo:org/repo:environment:prod`) is not trusted
   and the first CI apply fails with `Not authorized to perform
   sts:AssumeRoleWithWebIdentity`. Set it to `null` only if the apply job has no
   `environment:` key.
4. **Push to main.** `deploy.yml` builds the web image and the `-tools` image,
   pushes `<sha>` and `<sha>-tools` to ECR, runs
   `terraform apply -var image_tag=<sha>`, then `aws ecs run-task` on the tools
   family (`terraform output -json migration_run_task`) for migrations, and
   finally lets the web deployment roll. The circuit breaker rolls back
   automatically if the new tasks never become healthy.
5. **Restore the database** (migration host, see below), rehearse, then cut over
   DNS with `traffic_target = "aws"` and enable the crons.

## DNS: delegate early, cut over late

The cutover is a Route 53 record change, not a nameserver move, so it is
reversible in one apply and takes one TTL (60 s). The nameserver move happens
days earlier while traffic still flows to the old platform.

| When | Do | Effect |
|---|---|---|
| **T-7** | `create_hosted_zone = true` (or point at an existing zone). Copy **every** record from the old DNS provider: the public hostnames into `old_platform_records` (e.g. apex `A 76.76.21.21`, `www CNAME cname.vercel-dns.com`, or Railway's `CNAME xyz.up.railway.app`), everything else (MX, SPF/DKIM/DMARC TXT, verification TXT, CAA, tool CNAMEs) into `extra_dns_records`. `terraform apply`. Put `terraform output hosted_zone_name_servers` into the registrar's NS records. | Route 53 becomes authoritative but answers with the old platform's addresses: nothing changes for users. ACM validation CNAMEs are now live, so both certificates issue. Verify: `dig +short NS example.com` shows the AWS servers, `dig +short app.example.com` still shows the old IP, `dig +short MX example.com` is intact. |
| **T-1** | Rehearse: `curl --resolve app.example.com:443:<cloudfront or alb ip> https://app.example.com/` end to end; run the data-migration rehearsal with the migration host. | No DNS change. |
| **T-0** | Freeze writes on the old platform, final `pg_dump \| pg_restore`, then `traffic_target = "aws"` and `crons_enabled = true`, `terraform apply`. | `old_platform_records` are deleted and alias records to CloudFront / the ALB appear (apex + `additional_domain_names`). Within 60 s clients resolve to AWS. Schedules start firing. |
| **Rollback** | `traffic_target = "old"` (and `crons_enabled = false`), `terraform apply`. | Alias records removed, old-platform records restored, within 60 s. The old platform must still be running (keep it for the 7-day soak). |

Notes:

- `origin.<domain>` is created from the first apply regardless of the switch; it
  is not user-facing.
- A CNAME is not allowed at the zone apex, so `old_platform_records` for the
  apex must use the old provider's `A` (or `AAAA`) addresses. If the old
  platform only offers a CNAME for the apex, keep the apex at the old provider
  until T-0 and delegate at cutover instead (then expect certificates to issue
  only at T-0, or pre-create the validation CNAMEs at the old provider).
- `additional_domain_names` (www) are certificate SANs on CloudFront or the ALB,
  get records at T-0, and are 301-redirected to `domain_name` at the edge
  (CloudFront Function) or by an ALB listener rule when CloudFront is off.
- The hosted zone has `prevent_destroy`: destroying it would change the NS set
  and break the delegation.

## Cron safety

`cron_jobs` are created **paused** (`crons_enabled = false` by default). Until
cutover the old platform's crons still run against the live database; an
enabled AWS copy would run the same jobs twice (double emails, double invoices)
or run them against the frozen, half-restored RDS. Flip `crons_enabled = true`
in the same apply as `traffic_target = "aws"`, and pause the old platform's
schedules at the same time. `cron_capacity_provider` defaults to
`FARGATE_SPOT`; use `FARGATE` for jobs that cannot simply run again next time.

## Worker sizing

The worker reuses the web image and, by default, the web sizing: `worker_cpu`,
`worker_memory` and `worker_capacity_provider` are `null` = same as web.
Override them when the queue consumer needs more memory or can run on Spot.
`worker_desired_count` / `worker_min_capacity` / `worker_max_capacity` default
to 1 / 1 / 2 (CPU target tracking).

## Cache (ElastiCache for Valkey)

`enable_cache = true` creates a single-node `cache.t4g.micro` Valkey group
(cluster mode disabled, TLS required, no AUTH; the security group is the auth
boundary) and injects `REDIS_URL = rediss://<host>:6379/0` into every task.
`cache_maxmemory_policy = "noeviction"` for queues (BullMQ, Celery), `"allkeys-lru"`
for a pure cache. Queues cannot be copied; drain them on the old platform at
cutover. See `modules/valkey/README.md`.

## Migration host

`enable_migration_host = true` creates a `t4g.nano` Amazon Linux 2023 instance
inside the VPC, reachable only through SSM Session Manager, with the PostgreSQL
client for the target major (`migration_host_pg_major`, default = major of
`db_engine_version`), Docker as a fallback client, the RDS CA bundle, and read
access to the RDS master secret and the app secret. Its security group is
allowed on the RDS and Valkey security groups automatically.

```sh
$(terraform output -raw migration_host_session_command)          # shell on the host
terraform output -json migration_host_port_forward_commands     # laptop -> localhost:15432 -> RDS
```

Create it for the rehearsal and the cutover window; set it back to `false`
and apply after the day-7 checks (destroys the instance and its SG rules).
Runbook in `modules/migration_host/README.md`.

## One-off migration task

`migrations.tf` registers the task definition family `<project>-<env>-tools`:
the web task (same roles, env, secrets, log group, ARM64) running image
`<ecr>:<image_tag><tools_image_tag_suffix>` (default `-tools`) with
`migration_command` (default `["npm", "run", "db:migrate"]`). The deploy role may
`ecs:RunTask` this family only, and read the web log group. Outputs:

- `migration_task_family`, `migration_task_definition_arn`
- `migration_run_task` = `{ cluster, task_definition_family, subnets,
  security_groups, assign_public_ip, container_name, log_group }` for
  `aws ecs run-task --cluster ... --task-definition <family> --launch-type FARGATE --network-configuration ...`
  (log stream: `<container_name>/<container_name>/<task id>`).

Set `enable_migration_task = false` if the app has no migrations.

## Day-2 operations

| Task | Command |
|---|---|
| Deploy a new image | push to `main` (or `gh workflow run deploy.yml`) |
| Roll back | re-run `deploy.yml` on the previous commit, or `terraform apply -var image_tag=<old sha>` |
| Rotate a secret | `scripts/put_secrets.sh ...` then `aws ecs update-service --cluster $(terraform output -raw ecs_cluster_name) --service $(terraform output -raw ecs_service_name) --force-new-deployment` (ECS reads secrets only at task start) |
| Shell into a task | set `enable_execute_command = true`, apply, then `aws ecs execute-command --cluster ... --task ... --container app --interactive --command sh` |
| Tail logs | `aws logs tail $(terraform output -raw log_group_name) --follow` |
| Run a one-off command | `aws ecs run-task` on `migration_task_family` with `--overrides '{"containerOverrides":[{"name":"app","command":[...]}]}'`, network config from `migration_run_task` |
| Add a cron job | add to `cron_jobs` and apply (`crons_enabled` must be true for it to fire) |
| Scale | `min_capacity` / `max_capacity` / `cpu` / `memory` (and the `worker_*` equivalents) and apply |
| Flip DNS | `traffic_target = "aws"` or `"old"`, apply |

## Decommissioning (two applies, on purpose)

1. Set `deletion_protection = false`, `enable_migration_host = false` and apply
   (RDS and the ALB refuse deletes otherwise; not needed for the shared pieces,
   which stay).
2. Remove `prevent_destroy` from `modules/rds_postgres` (it is a literal, per
   the module README) and from `aws_route53_zone.this` in `dns.tf` if this
   root created the zone, make sure `final_snapshot_identifier` is unique, set
   `force_destroy = true` on the media bucket if it has objects, then
   `make destroy ROOT=live/example-app/prod`.

## Cost (us-east-1, defaults, Oct 2026 list prices)

| Item | Monthly |
|---|---|
| Fargate web task 0.5 vCPU / 1 GiB ARM64, 1 task | ~$12 |
| Public IPv4 for the task (no NAT) | ~$3.65 |
| ALB (hourly + 2 IPv4) | ~$24-28 |
| RDS db.t4g.micro, 20 GiB gp3, single AZ | ~$15 |
| Secrets Manager (1 secret + RDS master secret) | ~$0.80 |
| CloudWatch logs/alarms, SNS, budgets, Route 53 zone | ~$1-3 |
| CloudFront, S3 media (small site) | ~$0 (always-free tier) |
| **Total** | **~$55-65** |

Switches that change the bill: `db_multi_az = true` (+$15), `task_in_public_subnets = false`
(+$33 NAT), `min_capacity = 2` (+$12), `enable_waf = true` (+$9, +$1 per
`waf_path_rate_limits` entry), `enable_worker` (+$12), `enable_cache` (+$12),
`enable_migration_host` (+$5 while it exists), `container_insights = "enabled"`
(+$1-3). The ALB is the fixed cost that surprises Railway users; with
`shared_alb = true` and `shared_database = true` (the `platform/` root) a
project's own line shrinks to one 0.25 vCPU task ($7.21 on-demand / ~$2-3
Spot) + IPv4 $3.65 + secret $0.40 + its share of the ~$51 pool.

## Gotchas

- **`framework` shapes the baseline environment.** `nextjs` injects `NODE_ENV`,
  `HOSTNAME=0.0.0.0`, `NEXT_TELEMETRY_DISABLED`, `NEXT_PUBLIC_SERVER_URL`;
  `node` injects `NODE_ENV` and `HOSTNAME`; `python`/`other` get only `PORT`,
  `APP_URL` and `AWS_REGION`. Without `HOSTNAME=0.0.0.0` Node servers bind to
  localhost and the ALB health check never passes; Python servers must bind
  `0.0.0.0` on their command line (`uvicorn --host 0.0.0.0 --port $PORT`).
- **Health check path** must return 200-399 without auth and without the DB.
- **Container name is `app`** (`local.container_name`); scheduled tasks and the
  tools task use it, so it must match the ecs_service module's container name.
- **With CloudFront on**, the ALB certificate also covers `origin.<domain>` and
  the apex A/AAAA records move from the ALB to CloudFront. Turning CloudFront
  on later is a normal apply; expect ~5 minutes of propagation.
- **`create_image_cache_policy`** defaults to true for Next.js; set false for
  other frameworks and on CloudFront Free/Pro flat-rate plans.
- **`image_tag` is owned by Terraform.** Do not `aws ecs update-service` with a
  different image outside CI or the next apply reverts it.
- **The tools image must exist** (`<sha>-tools`) before the tools task can run;
  `deploy.yml` builds it from the Dockerfile's `tools` stage. Set
  `tools_image_tag_suffix = ""` to run migrations from the web image if it
  still contains the migration CLI.
- **Budget alerts need the cost-allocation tags** activated by bootstrap and up
  to 24 h before the first data shows.
- **Do not use Terraform workspaces** to add an environment; copy the directory.
