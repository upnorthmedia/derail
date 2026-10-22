# rds_postgres

One RDS for PostgreSQL instance, locked down the way a production database should be, sized the way a
Railway-sized app needs. Plain `aws_*` resources only; read `main.tf` top to bottom in five minutes.

## What it creates

| Resource | Purpose |
|---|---|
| `aws_db_subnet_group` | Places the instance in your private subnets |
| `aws_security_group` + ingress rules | TCP 5432 **only** from the security groups you list (ECS tasks, bastion). No CIDR rules, no egress |
| `aws_db_parameter_group` | Family derived from the major version (`postgres18`); `rds.force_ssl = 1` plus your `extra_parameters` |
| `aws_cloudwatch_log_group` (per exported log type) | Pre-created so exported engine logs get a retention instead of "never expire" |
| `aws_db_instance` | gp3, encrypted, `manage_master_user_password = true`, backups + PITR, deletion protection, final snapshot, Database Insights standard (free), `prevent_destroy` |
| `aws_cloudwatch_metric_alarm` x5 (optional) | CPU > 80 % (15 min), free storage < 2 GiB, connections > threshold, CPU credits < 20 (t-classes only), freeable memory < 100 MiB |

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Base name, e.g. `acme-prod`. Instance becomes `acme-prod-db` |
| `vpc_id` | string | required | VPC for the security group |
| `subnet_ids` | list(string) | required | Private subnet IDs (>= 2 AZs) |
| `allowed_security_group_ids` | list(string) | required | SGs allowed to connect on 5432 |
| `engine_version` | string | `"18"` | Major (`"18"`) or exact (`"17.6"`) PostgreSQL version |
| `parameter_group_family` | string | `null` | Override the derived `postgres<major>` family |
| `instance_class` | string | `"db.t4g.micro"` | Instance class |
| `allocated_storage` | number | `20` | Initial gp3 GiB |
| `max_allocated_storage` | number | `100` | Storage autoscaling ceiling (0 disables) |
| `multi_az` | bool | `false` | Synchronous standby in a second AZ (doubles cost) |
| `db_name` | string | `"app"` | Initial database name |
| `master_username` | string | `"postgres"` | Master user; password is RDS-managed |
| `backup_retention_period` | number | `7` | Days of automated backups / PITR (1-35) |
| `backup_window` | string | `"03:00-03:30"` | Daily UTC backup window |
| `maintenance_window` | string | `"sun:04:00-sun:05:00"` | Weekly UTC maintenance window |
| `deletion_protection` | bool | `true` | API-level delete protection |
| `kms_key_arn` | string | `null` | CMK for storage, logs and the managed secret (null = free AWS-managed keys) |
| `alarm_topic_arn` | string | `null` | SNS topic for alarms; null = no alarms |
| `connection_alarm_threshold` | number | `60` | `DatabaseConnections` alarm threshold |
| `apply_immediately` | bool | `false` | Apply changes now vs. next maintenance window |
| `enable_performance_insights` | bool | `true` | Database Insights standard mode, 7-day retention (free) |
| `enabled_cloudwatch_logs_exports` | list(string) | `["postgresql"]` | Engine logs shipped to CloudWatch (`[]` to disable) |
| `log_retention_days` | number | `14` | Retention for exported log groups |
| `extra_parameters` | map(object) | `{}` | `{ name = { value, apply_method = "immediate" \| "pending-reboot" } }` |

## Outputs

| Name | Description |
|---|---|
| `address` | Hostname for `DATABASE_URL` |
| `port` | 5432 |
| `db_name` | Initial database name |
| `master_username` | Master user name |
| `master_user_secret_arn` | ARN of the RDS-managed secret (`{"username","password"}` JSON). The ARN is safe to print; the value never touches Terraform |
| `security_group_id` | The DB security group (attach extra ingress rules here) |
| `instance_identifier` | For `aws rds ...` CLI calls |
| `instance_arn` | For IAM / AWS Backup selections |

## Cost (us-east-1, list prices Oct 2026)

| Item | Single-AZ | Multi-AZ |
|---|---|---|
| db.t4g.micro (2 vCPU / 1 GiB) | ~$11.68/mo | ~$23.36/mo |
| db.t4g.small (2 vCPU / 2 GiB) | ~$23.36/mo | ~$46.72/mo |
| 20 GiB gp3 | ~$2.30/mo | ~$4.60/mo |
| RDS-managed master secret | $0.40/mo | $0.40/mo |
| Automated backups | free up to 100 % of allocated storage | |
| Database Insights standard | free | |
| Exported `postgresql` log | pennies (errors only by default); covered by the 5 GB/mo CloudWatch free tier | |
| Alarms | first 10 per account free, then $0.10/alarm-month | |

Deliberately **not** enabled, because each one is a line item: Enhanced Monitoring (CloudWatch Logs
ingestion every N seconds), RDS Proxy ($21.90/mo minimum), Database Insights advanced
(~$18/mo for 2 vCPU), a customer-managed KMS key ($1/mo; pass `kms_key_arn` to opt in).

## Discovery tags (for sharing one instance between projects)

The `platform/` root creates this module once with `name = <platform_name>` and
`allowed_security_group_ids = []`; project roots with `shared_database = true` then find it without
remote state and add their own ingress rules:

| Resource | How a project root finds it |
|---|---|
| `aws_db_instance` | `data "aws_db_instance" { db_instance_identifier = "<name>-db" }` (also tagged `Name = "<name>-db"`) |
| `aws_security_group` | `data "aws_security_group"` filtered on `tag:Name = "<name>-db"` + `vpc-id` |
| master secret | `data.aws_db_instance.<x>.master_user_secret[0].secret_arn` |

Each project gets its **own database and roles inside the instance**
(`scripts/pg_migrate.sh roles --target-db <db> --app-owner <proj>_owner --app-rw <proj>_rw --app-migrate <proj>_migrate`);
roles are cluster-wide in PostgreSQL, so the names must not collide between projects. Size the
pools so that `sum(tasks x pool_size)` over every project stays under `0.8 x max_connections`
(~80-90 on a 1 GiB class, ~190 on db.t4g.small; `SHOW max_connections` tells the truth).

## How the app connects

1. The master secret is for migrations and admin. Create a least-privileged application role
   (`CREATE ROLE app LOGIN PASSWORD '...'; GRANT ...`) and store its URL in the project's app secret
   (see the `secrets` module and `scripts/put_secrets.sh`).
2. Always use TLS: `postgresql://app:...@<address>:5432/app?sslmode=verify-full` with the RDS CA bundle
   (`https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem`) baked into the image, or
   `sslmode=require` if you accept not verifying the server certificate.
3. Keep the app's pool small (`connection_limit=5` per task for Prisma; `max: 5-10` for `pg.Pool`).
   A 1 GiB instance allows roughly 80-90 connections in total.

## Gotchas

- **The master password rotates every 7 days** by default. Anything that caches the master password
  (a laptop `.env`) will break; the app should not use the master user at all. To stop rotation add an
  `aws_secretsmanager_secret_rotation` with `rotation_enabled = false` that references
  `master_user_secret[0].secret_arn` so Terraform orders it after the instance exists.
- **Tearing down is a deliberate three-step dance** (this is the point): (1) remove the
  `lifecycle { prevent_destroy = true ... }` block in `main.tf`, (2) set `deletion_protection = false`
  and set a *unique* `final_snapshot_identifier` (snapshot names cannot be reused; `acme-prod-db-final`
  will already exist after the first teardown), `terraform apply`, (3) `terraform destroy`. The final
  snapshot costs ~$0.095/GB-month until you delete it.
- **Static parameters need `apply_method = "pending-reboot"`** (e.g. `shared_preload_libraries`,
  `max_connections`). RDS rejects `immediate` for them, and the value only takes effect after the next
  reboot or maintenance window.
- **Changing `engine_version` across majors** is an in-place major upgrade with downtime, and the
  parameter group family changes with it (the module derives the family, so a new parameter group is
  created and swapped in). Prefer an RDS Blue/Green deployment for production majors.
- **`subnet_ids` must be private.** `publicly_accessible` is hard-coded `false`; a database in a public
  subnet with no public IP still works but it is one SG mistake away from the internet.
- **`apply_immediately = false`** means instance class and storage changes wait for the maintenance
  window. The plan still looks "applied"; check `aws rds describe-pending-maintenance-actions` /
  the `PendingModifiedValues` field if a change seems to have no effect.
- **Storage autoscaling** (`max_allocated_storage`) makes Terraform ignore later changes to
  `allocated_storage`; RDS owns the number from then on.
- The `exports` log groups are created before the instance (explicit `depends_on`) so RDS adopts them
  instead of creating untagged, never-expiring ones.
- **`allowed_security_group_ids` is indexed with `count`, not `for_each`.** The IDs are usually
  created in the same apply (the ECS task security groups), so they are unknown at plan time and
  `for_each` would fail the first plan with "Invalid for_each argument". `count` only needs the
  list length. Append new SGs at the END of the list; removing one from the middle re-creates the
  rules after it (a few seconds of churn, no downtime for existing connections).
