# AWS target architecture: tiers, decisions, and honest costs

Prices are us-east-1, verified 2026-10-22 (items marked ~ were derived or from secondary sources).
They will drift; `scripts/estimate_cost.py` holds the same numbers in one place.

## Contents
1. The shape of the default target
2. Three tiers (budget / standard / production) with line items
3. Decision: compute for each service (Fargate, Express Mode, OpenNext, Amplify, Lambda)
4. Decision: networking (public-subnet tasks vs NAT vs endpoints)
5. Decision: database (RDS PostgreSQL vs Aurora Serverless; pooling; versions)
6. Decision: cache, cron, worker, storage, edge
7. Observability and reliability baseline
8. Things that make AWS cost more than Railway, and what to say about it

## 1. Default target

```
Route 53 ──► (CloudFront + WAF, optional) ──► ALB (HTTPS, ACM) ──► ECS Fargate service (ARM64)
                                                                  │  web task(s), public subnet, SG from ALB only
                                                                  ├─ worker task (optional, same image)
                                                                  └─ EventBridge Scheduler → RunTask (cron)
                      S3 + CloudFront OAC (media)                 RDS PostgreSQL (private subnet, SG from tasks only)
                      Secrets Manager (one JSON secret per app/env) ← values written out-of-band
                      CloudWatch Logs/alarms → SNS email; Budgets + Cost Anomaly Detection per project
                      GitHub Actions via OIDC (plan / apply / deploy roles), S3 state with native locking
```

One shared VPC per account (`network/` root), one Terraform root per project per environment,
isolation by security groups + IAM roles + tags + separate state keys. This ports 1:1 to separate
AWS accounts later (never hard-code the account ID).

## 2. Tiers

| | Budget | Standard | Production |
|---|---|---|---|
| Web tasks | 1 x 0.25-0.5 vCPU / 1 GB ARM | 1-2 x 0.5 vCPU / 1 GB, autoscale to 2-4 | 2+ x 0.5-1 vCPU across 2 AZs |
| Task placement | public subnets + public IP (no NAT) | same | private subnets + NAT (or endpoints) |
| ALB | dedicated | dedicated | internal behind CloudFront VPC origin |
| CloudFront | Free plan if eligible, else none | Pro plan ($15, includes WAF, Route 53 zone) | PAYG + WAF managed rules |
| RDS | db.t4g.micro, single-AZ, 7-day backups | db.t4g.small, single-AZ | db.t4g.small/medium Multi-AZ, 14-35 day PITR, AWS Backup |
| Cache | none | Valkey Serverless if ISR/sessions need it | Valkey Serverless |
| Observability | free metrics, 10 alarms, logs 14-30 d | + Database Insights standard | + Container Insights enhanced, Synthetics canary |
| Rough total | ~$50/mo (~$30 if the ALB is shared) | ~$90/mo | ~$180-230/mo |

Budget line items (1 Next.js app + Postgres): Fargate 0.25 vCPU/1 GB ARM $8.51, task public IPv4
$3.65, ALB $16.43 + ~$2 LCU + 2 public IPv4 $7.30, RDS t4g.micro $11.68, gp3 20 GB $2.30, Secrets
Manager 2 x $0.40, Route 53 zone $0.50, logs within 5 GB free tier. Standard adds: 0.5 vCPU task
($14.42), CloudFront Pro $15, t4g.small $23.36, per-project KMS key $1, 3 secrets $1.20, optional
Valkey Serverless ~$6.13. Production adds: 2 tasks, NAT $32.85 + $0.045/GB, Multi-AZ (x2 instance
and storage), WAF PAYG ~$9, Container Insights ~$10, AWS Backup ~$2.

The irreducible floor for "always-on container + managed Postgres + HTTPS" is roughly **$30/mo with a
shared ALB or $50/mo dedicated**. Most of the gap versus Railway is ALB hours and public IPv4 fees,
not compute.

## 2b. Shared platform ("agency mode"): getting close to Railway's price

Railway's per-project price is low because the load balancer, TLS, and (effectively) the database host
are shared across every customer. The same trick works inside one AWS account: the optional
`platform/` root creates one ALB, one ECS cluster and one RDS instance that every small project in the
account uses, and each project root opts in with three flags (`shared_alb`, `shared_cluster`,
`shared_database`). Only the fixed-cost pieces are shared; secrets, task roles, log groups, buckets,
state and CI roles stay per project.

Per-project marginal cost (`scripts/estimate_cost.py --tier shared`, 4 tenants): 0.25 vCPU / 0.5 GB ARM
task $7.21, task public IPv4 $3.65, 1/4 of the ALB $6.43, 1/4 of a `db.t4g.small` + storage $6.42, one
secret $0.40, CloudFront Free plan $0 → **~$25/mo**. With `--spot-web` (Fargate Spot, brief 5xx on
the rare interruption unless 2 tasks) **~$20**; with 8 tenants and Spot **~$13**. The shared pool itself
(ALB ~$26 + RDS small ~$26 + alerts) shows up in Cost Explorer as `Project=platform`; divide it by
tenant count or map it with a Cost Category.

What sharing costs you, say it plainly in the plan: one RDS instance means one maintenance window, one
failover, one `max_connections` budget (~190 on `t4g.small`; `sum(tasks × pool) < 0.8 × max`), shared
deletion protection, and a noisy project can slow the others; one ALB means a unique
`listener_rule_priority` per project and a shared security group; a bad platform apply affects every
tenant. Graduate a project to dedicated resources (flip the three flags, dump/restore its database)
when it earns it: paying customers, compliance scope, or >1 GB of RAM steady-state. ECS Express Mode
is AWS's managed version of ALB sharing (up to 25 services per ALB) if you would rather not run the
`platform/` root yourself.

Other levers, in order of savings per effort: CloudFront Free plan instead of PAYG + WAF (~$9);
0.25 vCPU/0.5 GB task instead of 0.5/1 (~$7); Spot for workers and crons (~70%); `db.t4g.micro` for
anything under ~1 GB working set (~$12 vs ~$23); no NAT (public-subnet tasks); 14-day log retention;
no Container Insights; share the Route 53 zone (one zone per agency domain, project hostnames as
subdomains) when clients do not own their domain.

## 3. Compute per service

Default: **ECS Fargate (ARM64/Graviton, ~20% cheaper than x86)** through the `ecs_service` module.
It is the closest model to Railway (container in, service out), works for any language, has no
request-size or duration limits, supports WebSockets, and the generated Terraform is plain resources
a newcomer can read. Smallest task 0.25 vCPU / 0.5 GB ARM = ~$7.21/mo; recommended floor 0.25/1 GB
($8.51), default 0.5/1 GB ($14.42). Payload CMS admin + sharp: start at 1 vCPU / 2 GB.

| Option | Use when | Avoid when |
|---|---|---|
| **ECS Fargate + ALB** (default) | Needs private RDS, long requests, WebSockets, Payload admin, any non-Node runtime, team wants one pattern | Idle hobby app where $50/mo is unacceptable |
| **ECS Express Mode** (`aws_ecs_express_gateway_service`, GA Nov 2025, free) | Many small services in one account: up to 25 share one ALB (~$25/mo amortised); AWS's App Runner replacement | You need per-project ALB tagging/isolation or custom listener rules (the module gives more control) |
| **OpenNext on Lambda** (`@opennextjs/aws` 4.1.x via SST v4 or a community Terraform module) | Next.js only, spiky/low traffic, heavy ISR/on-demand revalidation, cheap per-PR stages; ~$1-10/mo compute | DB must stay private (Lambda-in-VPC needs NAT ~$33/mo for Stripe/Twilio egress), Payload admin cold starts, bundle near 250 MB, Terraform-purist team (SST is Pulumi-based; TF modules lag OpenNext) |
| **Amplify Hosting (managed)** | Next.js <= 15, no VPC needs, want git-push + PR previews with zero ops | Next 16 (docs list 12-15 only), on-demand ISR, streaming, private RDS (no VPC access for compute), egress $0.15/GB |
| **Lambda Web Adapter + Function URL** | Near-zero traffic internal tools | Cold starts 1-3 s, 10 MB responses |
| **App Runner** | never for new work: closed to new customers in 2026 | |

Decision rule the skill applies: Fargate unless the app is Next.js AND (traffic is spiky or ISR is
central or cost must be <$20/mo) AND the database can be reached from Lambda without NAT (public
endpoint with TLS + SG, or Neon/Aurora public), in which case offer OpenNext/SST and explain that it
is a different toolchain. Express Mode is offered when the account will host 3+ small web services.

## 4. Networking

| Option | Monthly | Verdict |
|---|---|---|
| **A. Tasks in public subnets with public IPs, strict SGs** | $3.65 per running task | **Default for budget and standard.** No inbound is reachable except from the ALB SG; RDS stays in private subnets reachable only from the task SG. This is also what Express Mode does. |
| B. Private subnets + NAT Gateway | $32.85 + $0.045/GB (+$3.65 IP) | Production tier, or when policy says "no public IPs on compute". |
| C. Private subnets + VPC interface endpoints | 4 endpoints (ecr.api, ecr.dkr, logs, secretsmanager) = $29.20/mo per AZ; $58.40 for 2 AZs | Usually a loss for one app; only wins when shared across many projects in one VPC, and third-party egress still needs NAT. |
| D. fck-nat / NAT instance | ~$6.72 | Middle ground for private-subnet purists; one EC2 instance to patch. |
| E. IPv6-only | | Not yet: Fargate task launch dependencies still need an IPv4 route; ECS Exec unsupported. Revisit 2027. |

Public IPv4 costs $0.005/hr for every address (ALB uses 2, NAT 1, each public task 1). Always: S3
gateway endpoint (free), DNS hostnames/support on, flow logs only in prod.

## 5. Database

- **RDS for PostgreSQL** on `db.t4g.micro` ($11.68) / `db.t4g.small` ($23.36) / `db.t4g.medium`
  ($47.45), gp3 20 GB ($2.30, 3,000 IOPS included), storage autoscaling to 100 GB, automated backups
  free up to 100% of storage, Database Insights standard (free, 7 days), `rds.force_ssl=1` (default on PG 15+).
- **Versions:** PostgreSQL 18 is GA on RDS (since Nov 2025) and Aurora (since June 2026); current 18.6.
  Keep the **same major as the source** so pg_dump/pg_restore is boring. PG 14-17 also available.
- **Aurora Serverless v2** scales to 0 ACU, but 0.5 ACU always-on = $43.80/mo (3.75x a t4g.micro); it
  wins only for apps idle >75% of the time, with 15 s resume and no RDS Proxy. Opt-in only.
- **Multi-AZ** doubles instance and storage cost; failover 60-120 s. Production tier.
- **Pooling:** app-level pool (~10 per task) by default. RDS Proxy has a 2 vCPU minimum ($21.90/mo),
  pins sessions on prepared statements/SET/LISTEN, and blocks Aurora pausing. A PgBouncer sidecar only
  if there are hundreds of short-lived connections. `max_connections` = LEAST(DBInstanceClassMemory/9531392, 5000)
  (~80-110 on t4g.micro, ~190 on t4g.small).
- **Credentials:** `manage_master_user_password = true` (RDS-owned secret, rotates every 7 days, never
  in state). Create a least-privilege app role (`scripts/sql/app_roles.sql.tpl`) and put its URL in the
  app secret. IAM DB auth is optional and a poor fit on 1 GiB instances.
- **Redis/Valkey:** ElastiCache Serverless Valkey has a 100 MB minimum (~$6.13/mo idle, Multi-AZ,
  TLS); `cache.t4g.micro` Valkey node $9.34. Railway Redis is plaintext `redis://`; ElastiCache needs
  `rediss://` + AUTH token. Often the right answer is no Redis: Postgres (SKIP LOCKED, pg_cron) or SQS.

## 6. Cache, cron, worker, storage, edge

- **Cron:** EventBridge Scheduler -> `ecs:RunTask` on the web task definition with a command override
  (`scheduled_task` module; Fargate Spot by default). 6-field cron, time-zone aware, retries, no
  overlap skipping (add a DB lock if runs can overlap). Vercel-style HTTP crons: EventBridge rule ->
  API destination with the bearer header, if the route must stay.
- **Worker:** second `ecs_service` from the same image, `expose_http = false`, optionally
  `FARGATE_SPOT` (up to 70% off, 2-minute interruption notice).
- **Storage:** S3 private bucket + CloudFront OAC for uploads/media (`s3_media` module, task role
  access, no access keys). EFS only when the app must read files back by path and cannot be refactored.
  SQLite on a volume -> RDS, or EFS as a single-task stopgap.
- **Edge:** CloudFront in front of the ALB gives free TLS at edge, HTTP/3, caching of
  `/_next/static/*`, WAF attachment, and (Business plan or PAYG) VPC origins so the ALB can be
  internal. Flat-rate plans (Nov 2025): Free $0 (1 M req, 100 GB, 5 WAF rules, Route 53 zone
  included; not available on the Free Tier account plan, WAF ACL mandatory), Pro $15 (10 M req, 50 TB,
  25 WAF rules), Business $200 (VPC origins, custom policies). PAYG: 1 TB + 10 M req always free.
  The `cloudfront_app` module uses Next.js-aware behaviors (static immutable, `/_next/image*` keyed on
  `url,w,q`, `/api/*` uncached with all headers forwarded so webhook signatures survive, default keyed
  on Host + cookies + query strings with origin Cache-Control honored). Origin read timeout caps at 60 s.
- **WAF:** AWSManagedRulesCommonRuleSet (body-size and XSS-body rules in count mode to spare CMS admin
  saves), AmazonIpReputationList, KnownBadInputs, rate-based rule (replaces Vercel Attack Mode). PAYG
  ~$9/mo; included in CloudFront plans.

## 7. Observability and reliability baseline

Generated by the modules: ALB target 5xx and unhealthy-host alarms, ECS CPU/memory alarms, RDS CPU /
free storage / connections / credit balance / freeable memory alarms, deployment circuit breaker with
rollback, container + ALB health checks on `/api/health`, log groups with retention, SNS email topic per
project, per-project tag-filtered Budget (80% actual, 100% forecast) and Cost Anomaly monitor, RDS
automated backups + deletion protection + final snapshot. 10 alarms are free, then $0.10 each.
Container Insights is off at budget tier (~$10/mo at enhanced). Uptime from outside: Route 53 health
check ($0.50, first 50 free) or CloudWatch Synthetics (~$2.6/mo at 5-min) in production. ECS Exec
(`aws ecs execute-command`) replaces `railway ssh`; enable per environment.

## 8. Why the AWS bill is higher, in one paragraph for the user

Railway bills per-minute actual CPU/RAM with free builds, TLS, CDN and private networking; AWS bills
the reserved Fargate size 24/7 plus fixed hourly fees for the load balancer (~$16) and every public
IPv4 address ($3.65). A $5-20/mo Railway app therefore lands at ~$50/mo on AWS at budget tier, or
~$30/mo when several projects share one ALB (Express Mode, or a shared ALB root). What you buy: a
database with PITR, Multi-AZ and deletion protection, IAM-scoped per-project isolation, a real WAF,
per-project budgets and anomaly alerts, and infrastructure that is yours to audit. The cost estimate
step in the plan must show both numbers and the alternatives (shared ALB, OpenNext, Spot workers).
