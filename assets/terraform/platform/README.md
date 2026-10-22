# platform

The optional **shared platform** for an account that hosts several small
projects: one ECS cluster, one Application Load Balancer and one RDS PostgreSQL
instance that every `live/<project>/<env>` root can opt into with
`shared_cluster`, `shared_alb` and `shared_database`. Apply it **once per
account**, after `network/` and before the first project that uses it.

Why it exists: a dedicated stack per project costs ~$55-65/month, of which the
ALB (~$25) and the RDS instance (~$12-23) are fixed costs that a Railway-sized
site never uses to capacity. Shared, each project's marginal cost drops to one
small Fargate task plus a slice of the pool, which is the Railway price point.

## What gets created

| Resource | Name | Notes |
|---|---|---|
| ECS cluster | `<platform_name>` | FARGATE + FARGATE_SPOT capacity providers. Free; sharing only reduces console noise. |
| ALB + ACM certificate + SG (`modules/alb_https`) | `<platform_name>-alb` | Tagged `Shared = "true"`. HTTPS listener's default certificate is `platform_domain_name` (answers `404 no rule matched`); projects attach their own certificates (SNI) and host-header rules. `deletion_protection`. |
| Route 53 alias | `platform_domain_name` -> ALB | In `platform_hosted_zone_name`. `https://<platform_domain_name>` returning 404 is the ALB's own health check. |
| RDS PostgreSQL (`modules/rds_postgres`) | `<platform_name>-db` | `db.t4g.small`, 20 GiB gp3 autoscaling to 200, no ingress rules of its own (projects add theirs), `deletion_protection`, `prevent_destroy`, alarms. SG tagged `Name = "<platform_name>-db"`. |
| SNS topic, budget, anomaly monitor (`modules/budget_alerts`) | `<platform_name>-<environment>-alerts` / `-monthly` / `-anomalies` | Filtered on `Project = <platform_name>`. |

Everything is tagged `Project = <platform_name>` (`platform` by default), so
the shared pool is its own line in Cost Explorer, separate from every project.

Deliberately **not** shared: secrets, task roles, log groups, buckets, ECR
repositories, Terraform state. Those stay per project so one project's destroy,
IAM policy or log retention never touches another's.

## Cost (us-east-1, Oct 2026 list prices)

| Item | Monthly | Shared by |
|---|---|---|
| ALB hours + 2 public IPv4 + a fraction of an LCU | ~$25 | every project with `shared_alb = true` |
| RDS db.t4g.small single-AZ | ~$23.36 | every project with `shared_database = true` |
| 20 GiB gp3 + RDS-managed secret | ~$2.70 | |
| ECS cluster, SNS, budget, anomaly monitor | $0 | |
| **Total** | **~$51** | |

With N projects on it, each pays ~$51/N for the pool plus its own task:

| Projects sharing | Pool share per project | + smallest web task (0.25 vCPU / 0.5 GiB) | Per-project total |
|---|---|---|---|
| 1 | $51 | $7.21 on-demand + $3.65 IPv4 + $0.40 secret | ~$62 (no better than dedicated) |
| 4 | $13 | same | ~$24 (~$19 on Spot) |
| 8 | $6.40 | same | ~$18 (~$13 on Spot) |

`db_multi_az = true` adds ~$23 to the pool; `db.t4g.medium` adds ~$24. Project
budgets (`monthly_budget_usd` in the live roots) only see the project's own
tagged resources; the pool is in this root's budget.

### Splitting the pool across projects in Cost Explorer

The `Project = platform` line cannot be attributed automatically. Two options:

1. **Simple division**: pool cost / number of tenants. Good enough for an
   internal view; put the number in the agency's price sheet.
2. **Cost Category** (Billing console -> Cost Categories): a rule that maps
   `Tag Project = platform` with a *split charge* rule, allocating the
   platform category to the project categories proportionally (by their own
   cost), evenly, or by fixed percentages. Cost Categories are free and show up
   as a dimension in Cost Explorer and CUR.

## Blast radius: read before sharing

Sharing trades isolation for money. Know what you are giving up:

- **One RDS instance = one maintenance window, one failover, one
  `max_connections`.** A minor-version upgrade or a Multi-AZ failover restarts
  every tenant's database at once. `db.t4g.small` allows roughly **190
  connections** (`SHOW max_connections`; RDS derives it from memory). A noisy
  project (a leaking pool, an N+1 reporting page, a runaway migration) can
  starve the others of connections, CPU credits or IOPS.
- **Budget rule**: `sum over projects (tasks x pool_size) < 0.8 x max_connections`.
  Example on t4g.small: 6 projects x 2 tasks x 5 connections = 60, fine; 6
  projects x 4 tasks x 20 = 480, not fine. Set each app's pool explicitly
  (Prisma `connection_limit=5`, `pg.Pool max: 5`), and `max_capacity` low.
- **`deletion_protection` and `prevent_destroy` protect all tenants at once**,
  which also means decommissioning one project never touches the instance:
  drop its database and roles by hand (below).
- **Backups and PITR are per instance.** Restoring one project to a point in
  time means restoring the whole instance to a new one and `pg_dump`-ing that
  project's database out of it. Fine as a procedure, slower than Railway's
  per-service restore.
- **One ALB = one idle timeout, one TLS policy, one security group, one set of
  access logs**, and a hard quota of **25 certificates per listener**, so at
  most ~24 projects per shared ALB. ALB-level DDoS or a misbehaving tenant's
  5xx storm shows up in everyone's metrics (per-target-group metrics still
  separate them).
- **One cluster**: the per-project deploy roles may `ecs:ListTasks` /
  `DescribeTasks` across the shared cluster (read-only metadata). `UpdateService`
  and `RunTask` stay limited to the project's own services and task family.
- **When a project earns it, move it out**: flip `shared_database = false`
  (new dedicated instance; migrate with `scripts/pg_migrate.sh dump/restore`
  from the shared instance), then `shared_alb = false` (new ALB, same DNS
  cutover switch as the initial migration). Both are normal applies.

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `platform_name` | no | `platform` | Must match `network/` and every project root's `platform_name`. Names the cluster, ALB and database. |
| `environment` | no | `prod` | Environment tag. |
| `repository` | **yes** | | `github.com/org/repo` (Repository tag). |
| `aws_region` | no | `us-east-1` | Must match the network root and the projects. |
| `create_shared_alb` | no | `true` | Create the shared ALB. |
| `platform_domain_name` | **yes** | | The platform's own hostname on the ALB (listener default certificate), e.g. `apps.example-agency.com`. |
| `platform_hosted_zone_name` | **yes** | | Existing public zone containing it, e.g. `example-agency.com`. |
| `alb_idle_timeout` | no | `60` | Shared by every tenant; pick the largest any needs. |
| `create_shared_database` | no | `true` | Create the shared RDS instance. |
| `db_instance_class` | no | `db.t4g.small` | ~$23/month, max_connections ~190. |
| `db_engine_version` | no | `"18"` | Shared by every tenant. |
| `db_allocated_storage` | no | `20` | GiB. |
| `db_max_allocated_storage` | no | `200` | Autoscaling ceiling. |
| `db_multi_az` | no | `false` | Doubles the instance price; failover in 1-2 min for every tenant. |
| `db_backup_retention_period` | no | `7` | Days of PITR. |
| `db_connection_alarm_threshold` | no | `130` | ~0.7 x max_connections. |
| `deletion_protection` | no | `true` | On the ALB and the database. |
| `container_insights` | no | `disabled` | Shared cluster setting (costs per tenant service when enabled). |
| `alert_email` | **yes** | | Pool alarms, budget, anomalies. |
| `monthly_budget_usd` | no | `100` | Budget on `Project = <platform_name>`. |

## Outputs

| Name | Description |
|---|---|
| `cluster_name`, `cluster_arn` | Shared cluster. |
| `alb_arn`, `alb_dns_name`, `alb_zone_id`, `alb_https_listener_arn`, `alb_security_group_id`, `platform_url` | Shared ALB (null when `create_shared_alb = false`). |
| `db_identifier`, `db_address`, `db_port`, `db_security_group_id`, `db_master_user_secret_arn` | Shared database (null when `create_shared_database = false`). |
| `alerts_topic_arn` | The pool's SNS topic. |

Project roots do **not** read these outputs. They discover the shared pieces
by name/tag:

| Piece | Project root lookup |
|---|---|
| Cluster | `data "aws_ecs_cluster" { cluster_name = var.platform_name }` |
| ALB | `data "aws_lb" { tags = { Name = "<platform_name>-alb", Shared = "true" } }`, then `data "aws_lb_listener" { load_balancer_arn, port = 443 }`; the ALB SG is `security_groups[0]` (the root asserts there is exactly one) |
| Database | `data "aws_db_instance" { db_instance_identifier = "<platform_name>-db" }` and `data "aws_security_group"` on `tag:Name = "<platform_name>-db"` (asserted to be attached to that instance) |

## How to run

```sh
cd platform
# edit backend.tf: bucket and region from `terraform -chdir=../bootstrap output`
cp terraform.tfvars.example terraform.tfvars   # edit
terraform init
terraform plan
terraform apply                                 # ~10 min, mostly RDS
```

Prerequisites: `bootstrap/` and `network/` applied; the zone
`platform_hosted_zone_name` already delegated to Route 53 (otherwise the ACM
validation for `platform_domain_name` never completes).

## How to add a project

1. Copy `live/example-app/prod` as usual and set, in its `terraform.tfvars`:

   ```hcl
   shared_cluster         = true
   shared_alb             = true
   shared_database        = true
   listener_rule_priority = 120          # unique per project, see the table below
   cpu                    = 256
   memory                 = 512
   capacity_provider      = "FARGATE_SPOT"
   ```

   The project still gets its own certificate (attached to the shared
   listener by SNI), its own host-header rules at `listener_rule_priority` and
   `+ 1`, its own secrets, roles, log group, ECR repository and budget.

2. **Allocate a priority** and record it here. Every project needs two
   consecutive numbers (web rule and the www redirect rule). Two projects with
   the same number fail at apply with `PriorityInUse`.

   | Priority (web, redirect) | Project / environment | Hostnames |
   |---|---|---|
   | 100, 101 | *(reserved: the default; never use it on the shared ALB)* | |
   | 110, 111 | `example-app/prod` | `app.example.com`, `www.example.com` |
   | 120, 121 | | |
   | 130, 131 | | |

3. **Create the project's database and roles** in the shared instance, from
   the project's migration host (`enable_migration_host = true`; it can read
   the platform master secret via the project's `db_master_secret_arn`
   output) or any host inside the VPC. Roles are cluster-wide in PostgreSQL,
   so prefix them with the project:

   ```sh
   # TGT_URL = master user of the shared instance, database "postgres"
   export TGT_URL="postgresql://postgres:<master pw>@$(terraform output -raw db_endpoint):5432/postgres?sslmode=verify-full&sslrootcert=global-bundle.pem"
   APP_RW_PASSWORD=... APP_MIGRATE_PASSWORD=... \
     scripts/pg_migrate.sh roles --target-db $(terraform output -raw db_name) \
       --app-owner acme_shop_owner --app-rw acme_shop_rw --app-migrate acme_shop_migrate
   ```

   `roles` creates the database if it is missing; `restore --target-db <db>
   --role acme_shop_owner` does too. Then `DATABASE_URL` in the project's app
   secret (`scripts/put_secrets.sh`) points at
   `<db_endpoint>:5432/<db_name>` with the `_rw` role: the master user is
   never used by an application. This is the same out-of-band step as the app
   secrets themselves: Terraform creates the container, never the value.

4. `make plan`/`make apply` the project root; the rest of its runbook (DNS
   cutover switch, crons, migrations) is unchanged.

## Removing a project

`make destroy` on the project root removes its listener certificate, rules,
target group, ingress rules on the shared DB SG and everything else it owns;
the shared ALB, instance and cluster are untouched. Then, by hand, on the
shared instance: `DROP DATABASE <db>; DROP ROLE <proj>_rw, <proj>_migrate,
<proj>_owner;` (take a final `pg_dump` first), and free the priority row above.

## Decommissioning the whole platform

Only after every project has `shared_* = false` (or is gone): set
`deletion_protection = false`, apply; remove `prevent_destroy` from
`modules/rds_postgres` (and set a unique `final_snapshot_identifier`), then
`terraform destroy`. The project roots' data sources fail loudly if a shared
piece disappears underneath them, which is the intended safety net.

## Gotchas

- **Edit `backend.tf` first** (placeholder account id), like every root.
- **`platform_name` is a contract** with `network/` and every project root.
- **The default certificate only covers the platform hostname.** A project
  whose certificate failed to validate gets TLS errors, not the platform's
  404: check `aws_acm_certificate_validation` in that project's apply.
- **`alb_idle_timeout` is global.** Long-polling or large uploads in one
  project need the longest value for everyone.
- **Engine major is shared.** A project whose source database runs a
  different major must be dumped/restored across majors (test it in the
  rehearsal) or get its own instance.
- **Project budgets exclude the pool.** Set `monthly_budget_usd` in the
  project roots to the project's own share and keep the pool budget here.
- **Do not add project-specific things here.** Rules, certificates, ingress
  rules and databases for one project belong in that project's root (or in its
  out-of-band SQL), so the project can be removed cleanly.
