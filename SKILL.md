---
name: derail
description: Plan and generate a clean, secure, cost-aware migration of an application from Railway and/or Vercel to AWS (ECS Fargate, RDS PostgreSQL, S3/CloudFront, Secrets Manager) with Terraform, GitHub Actions OIDC, per-project billing and a step-by-step cutover runbook. Use this whenever someone wants to move, migrate, port, lift, or "get off" Railway or Vercel onto AWS, asks what it would cost or take to run their Railway/Vercel app on AWS, wants Terraform for an app that currently lives on a PaaS, needs to move a Railway Postgres or Vercel Blob store to RDS/S3, or asks for an AWS architecture or runbook for an existing Next.js/Node/Python app, or is leaving Railway after its October 2026 environment-variable breach and needs exposed secrets rotated first, even if they never say the word "migrate".
---

# Railway / Vercel to AWS migration

You are producing a migration package someone else could execute: an inventory, a decided
architecture with an honest cost comparison, validated Terraform, a Dockerfile, CI workflows, the
application code changes, data-migration scripts, and a cutover runbook. You do **not** run
`terraform apply`, flip DNS, or delete anything on Railway/Vercel. Humans do that with the runbook.

Why this shape: Railway and Vercel hide a lot (TLS, ports, private DNS, builds, secrets at build time,
restart-on-crash, scale-to-zero billing). A migration goes wrong when those implicit behaviours are
rediscovered in production. The workflow below surfaces every one of them before any resource exists.

## Non-negotiables

1. **Secret values never appear in chat, files you author, plans, or logs.** The inventory scripts write
   values only to `migration/.secrets/` (umask 077, git-ignored) and print names. Never `cat` those
   files, never run `GetSecretValue`/`list-variables` and echo values, never paste a `DATABASE_URL`.
   If an MCP tool returns values (Railway `list-variables` does), use only the key names.
2. **Treat the migration as a secret-rotation event.** Vercel Secret-type and Railway sealed variables
   cannot be exported; exported values sat on a laptop. The plan lists what gets re-sourced, what stays
   identical through cutover (`PAYLOAD_SECRET`, auth secrets), and what rotates after. In breach mode
   (Phase 0) nothing stays identical: exposed values rotate now and session secrets rotate at cutover.
3. **Same PostgreSQL major on both sides.** RDS and Aurora support PG 14-18 (18 GA). Never propose a
   downgrade; `pg_dump` cannot do it safely.
4. **Generate, validate, hand over.** Every Terraform root you emit must pass `terraform fmt -check`,
   `terraform init -backend=false && terraform validate`, and `tflint` before you call it done.
5. **Show the real cost.** A $5-20/mo Railway app lands at ~$50/mo on AWS with dedicated resources,
   ~$25/mo when the account shares one ALB and one RDS instance across projects (`--tier shared`),
   ~$13-20 with Spot and more tenants. Say so, itemise it (`scripts/estimate_cost.py`), and show the
   alternatives side by side.
6. **Nothing destructive on the source.** No deleting services, volumes, Blob stores or domains. The
   runbook schedules decommissioning 7-14 days after a verified cutover.
7. **Nothing on AWS acts on the live system before the flip.** Schedules are created disabled
   (`crons_enabled = false`), public DNS records point at the old platform (`traffic_target = "old"`)
   until the cutover minute, and only the maintenance switch (never the full migration branch) is
   deployed to the old platform beforehand. When the app's public URL is a platform-provided hostname
   registered with a third party (Shopify app URL, OAuth callbacks, bot endpoints), the switch is that
   third-party config, a new custom hostname may go live early, and `references/app-changes.md` section 9
   applies.
8. **Sealed or Secret-type values are re-issued, never recovered.** Do not suggest reading them out of
   a running container's process environment; the migration is a rotation event anyway.

## Phase 0: Preflight (5 minutes)

- Confirm the shape with the user if unknown: which platforms (Railway only, Vercel only, both),
  one project or several, target region, AWS account state (fresh account? other projects already in
  it?), domain/DNS location, downtime tolerance, rough traffic, and budget sensitivity. One short set of
  questions; everything else you discover.
- Run `scripts/check_prereqs.sh --pg-major <source major>` (and `--no-railway`/`--no-vercel` as
  appropriate). Report missing tools; keep going with what exists (the AWS and Railway/Vercel MCP
  servers can replace the CLIs for discovery).
- Create `migration/` at the repo root with `.secrets/` git-ignored. All outputs land there
  (layout in "Deliverables" below).
- **Breach check (one question, always asked).** "Were these values stored on Railway on or after
  2026-10-21, or exposed some other way?" Railway disclosed that attackers read customer environment
  variables that day. If the user says yes, or the prompt already says so, run **breach mode**: read
  `references/breach-response.md` before Phase 1 and follow it. Its first step (`scripts/breach_check.sh
  --fingerprint`) must run before anyone rotates anything. If the answer is no, skip every breach-mode
  step; nothing else in this skill changes. If it is unknown and the user is unreachable, assume no and
  list the question first in PLAN.md's open questions.

## Phase 1: Discover

Goal: `migration/inventory/` with everything the platforms know, everything the code assumes, and a
gap list. Read `references/railway-inventory.md` and `references/vercel-inventory.md` for the
primitive-by-primitive mapping while you do this.

1. **Railway**: `scripts/railway_inventory.sh --project <id|name> --environment production` (or the
   Railway MCP tools: `list-projects`, `describe-environment`, `describe-service`, `get-service-config`,
   `list-domains`, `list-tcp-proxies`, `list-webhooks`, `get-service-metrics`). Capture per service:
   source (repo/image, root dir), builder, build/start/pre-deploy commands, healthcheck, replicas and
   regions, cron, volumes, domains, TCP proxies, variable names by class, and for databases whether
   PgBouncer/HA/PITR is on and the engine major. Pull `railway usage` for the before-cost.
   Save the raw `railway status --json` / `.railway/railway.ts` and the deprecated `railway.json` if present.
2. **Vercel**: `scripts/vercel_inventory.sh --project <name> --team <slug>` (or MCP `get_project`,
   `filter_project_envs`, `list_project_domains`, `get_firewall_config`, `list_project_routes`). Capture
   framework and Node version, domains, env var names with **Secret vs Config**, `vercel.json` crons /
   rewrites / headers, Blob stores, Marketplace databases, deployment protection, firewall rules.
3. **Codebase**: `python3 scripts/scan_codebase.py <repo> --out migration/inventory/codebase.json --md migration/inventory/CODEBASE.md`.
   It detects framework, package manager, Node/Python version, Dockerfile, Payload/Prisma/Drizzle/
   Better Auth, edge-runtime routes, ISR usage, Vercel-only imports, env var references, hard-coded
   platform hostnames, health endpoints, crons and webhooks, and emits a "Migration flags" list. If the
   repo is not available locally, ask for it or read it through GitHub; do not guess the stack.
4. **Gap list**: compare env var names referenced in code vs present on the platform vs classified;
   list sealed/Secret values that must be re-sourced; list implicit platform features in use (ISR,
   serverless sleeping, PR environments, static IPs, private networking between services).

Write `migration/inventory/INVENTORY.md`: one table per platform, the variable classification, the
code flags, the gap list, and the current monthly spend. This file is what the user reviews first.

## Phase 2: Decide

Goal: `migration/PLAN.md` with decisions the user can accept or change in one pass. Read
`references/aws-target-architecture.md` (tiers, decision matrices, prices) and keep these rules:

- **Tier**: shared (agency mode: the `platform/` root's ALB, cluster and RDS instance are shared by
  every small project; ~$25/mo per project, ~$13-20 with Spot and more tenants), budget (dedicated
  ALB and `t4g.micro`, public-subnet tasks, no NAT, CloudFront Free plan if eligible, ~$50), standard
  (`t4g.small`, CloudFront Pro + WAF, Valkey if needed, ~$90), production (Multi-AZ, private subnets
  + NAT, 2+ tasks, AWS Backup, Container Insights, ~$180+). When the account already hosts or will
  host three or more small sites and the user cares about matching Railway's price, recommend shared
  and state its blast-radius tradeoffs (one DB instance, one maintenance window, shared connections);
  budget for a single hobby site; standard for anything with paying customers; let the user pick.
  Always print the per-project marginal cost next to the shared-pool cost.
- **Compute per service**: ECS Fargate (ARM64) is the default for web, worker and cron. Offer ECS
  Express Mode when the account will host three or more small services (one shared ALB). Offer
  OpenNext/SST only for Next.js apps that are spiky or ISR-heavy and whose database can be reached
  without a NAT gateway, and say it is a different toolchain. Never propose App Runner (closed to new
  customers) or managed Amplify for Next 16.
- **Database**: RDS PostgreSQL, same major as source, `db.t4g.micro` (budget) / `small` (standard),
  gp3 20 GB with autoscaling, app-level pooling (~10 per task). RDS Proxy and Aurora Serverless are
  opt-ins with their costs stated. PgBouncer parity: direct RDS restores session semantics.
- **Files**: Vercel Blob / Railway buckets / upload volumes -> S3 + CloudFront OAC with task-role
  access. EFS only when files must be read back by path.
- **Cron / worker**: EventBridge Scheduler -> RunTask (6-field cron, no overlap skipping; created
  disabled until cutover); worker as a second service from the same image (Spot acceptable).
- **Cache / queue broker**: no Redis unless the app needs it. Celery/BullMQ/RQ brokers get the
  node-based Valkey module (cluster mode disabled, TLS, `noeviction`); pure caches may use it with
  `allkeys-lru`. Railway Redis URLs were plaintext `redis://`; the app must accept `rediss://`.
- **Egress IP**: if a third party allow-lists Railway's static outbound IPs, the tasks go in private
  subnets behind a NAT gateway with a stable Elastic IP (`network`: `enable_nat_gateway`,
  `stable_nat_eip`), and the plan's critical path is getting that IP allow-listed.
- **Edge**: CloudFront in front of the ALB when the app serves static assets or needs WAF; the module's
  behaviors are Next.js-aware and forward webhook signature headers.
- **Next.js ISR**: pick one of `force-dynamic` + CDN `s-maxage`, a shared Valkey cache handler, or
  OpenNext (`assets/app-snippets/nextjs/cache-handler.md`).
- **Account model**: single account, shared VPC, one Terraform root per project per environment,
  separate CI roles and state keys per project, tags + per-project budgets (`references/security-and-billing.md`).

PLAN.md structure (use these headings):
`## Summary` (3-5 sentences) · `## Target architecture` (diagram in text, per-service table: Railway/Vercel
service -> AWS component, size, placement) · `## Decisions and alternatives` (tier, compute, DB,
files, cron, edge, ISR; each with the rejected option and why) · `## Cost` (output of
`scripts/estimate_cost.py --tier ... --railway-monthly <n>` plus the shared-ALB / OpenNext numbers) ·
`## Keyless scorecard` (below) · `## Secrets and rotation plan` (names only; three buckets: re-source,
keep identical through cutover, rotate after; in breach mode: re-source, rotate now, rotate at cutover)
· `## Application changes` (from `references/app-changes.md`, specific to the flags found)
· `## What Railway/Vercel did implicitly that you now own` · `## Risks and open questions`.

**Keyless scorecard** (every migration): count the unique secret-class variable names on the source
platforms (inventory classes `app_secret`, `database`, `bucket_credential`, plus sealed/Secret-type;
not `railway_injected`, `public_buildtime`, `build_tuning`, references) and the entries in `secret_keys`.
Show both numbers, then list what disappears and why, for example: bucket keys and `AWS_*` keys -> the
task role; the database superuser password and `DATABASE_PUBLIC_URL` -> the RDS-managed master secret
(the app user's password remains a secret); `RAILWAY_TOKEN`/`VERCEL_TOKEN` in CI -> GitHub OIDC. Use
this inventory's real names and counts; never estimate. Fewer long-lived secrets is fewer things to
leak next time, and users who are leaving after a breach care about exactly that.

Stop here and get the user's agreement before generating. If unattended, state the assumptions at the
top of PLAN.md and continue with the defaults above.

## Phase 3: Generate

Read `references/terraform-conventions.md` first. Then:

1. **Copy the Terraform skeleton** from `assets/terraform/` into `<repo>/infra/` (or a standalone
   infra repo if the user prefers; for an agency with several projects a shared infra repo holding
   `bootstrap/`, `network/`, `platform/` and `live/<project>/<env>/` per client is the natural shape):
   `bootstrap/`, `network/`, `platform/` (shared tier only), `modules/`, `live/<project>/<env>/`
   (renamed from `example-app/prod`), `Makefile`, `.tflint.hcl`, `.pre-commit-config.yaml`, `.gitignore`,
   `README.md`. Copy `assets/github-workflows/*.yml` to `.github/workflows/`.
2. **Fill the root**: `backend.tf` (bucket `tfstate-<account>-<region>`, key `<project>/<env>/terraform.tfstate`),
   `terraform.tfvars` from the inventory. Identity and shape: `project`, `environment`, `aws_region`,
   `repository`, `github_org/repo`, `github_environment` (must equal the `environment:` of the apply job
   in `terraform.yml`, default `prod`, or the OIDC subject is not trusted), `framework`
   (`nextjs|node|python|other`, drives the base env), `domain_name`, `hosted_zone_name`,
   `additional_domain_names` (www), `alert_email`, `monthly_budget_usd`. Compute: `container_port`,
   `health_check_path`, `cpu`/`memory` (Railway metrics p95; CMS admin with sharp: 1024/2048),
   `desired_count`/`min_capacity`/`max_capacity`, `task_in_public_subnets`, `enable_worker` +
   `worker_command` (+ `worker_cpu/memory/capacity_provider`), `cron_jobs` (6-field EventBridge
   expressions, UTC) with `crons_enabled = false` until cutover. Data: `db_instance_class`,
   `db_engine_version` (= source major), `db_multi_az`, `enable_cache` (Valkey, for Celery/BullMQ/
   sessions), `enable_media_bucket` + `media_cdn` (false for private documents) + `media_domain_name`.
   Config: `secret_keys` (every secret-class name from the inventory plus `DATABASE_URL`), `plain_env`
   (non-secret config). Edge: `enable_cloudfront`/`enable_waf`/`waf_path_rate_limits`. DNS cutover:
   `create_hosted_zone` (when the zone moves to Route 53), `traffic_target = "old"`,
   `old_platform_records` (apex/www values that currently point at Vercel/Railway so a delegated zone
   keeps serving the old site), `extra_dns_records` (MX/TXT/CNAME copied from the old provider).
   Shared platform (tier shared): `shared_cluster`, `shared_alb` + `listener_rule_priority` (unique per
   project on that ALB; keep the table in `platform/README.md`), `shared_database` + `shared_db_name`
   (the project's own database inside the shared instance; created with `pg_migrate.sh roles`), and
   `cpu = 256`, `memory = 512`, optionally `capacity_provider = "FARGATE_SPOT"`. The `platform/` root
   must exist first (once per account, like `network/`).
   Migration: `migration_command` (Payload `["npx","payload","migrate"]`, Drizzle `["npx","drizzle-kit","migrate"]`,
   Prisma `["npx","prisma","migrate","deploy"]`, Alembic `["alembic","upgrade","head"]`),
   `tools_image_tag_suffix` (`""` for Python, which has no separate tools image), `enable_migration_host`
   (SSM-only EC2 for dump/restore inside the VPC; destroy after). If the account already has
   `bootstrap/` and `network/` applied for another project, say so and skip them.
3. **Dockerfile**: pick `assets/docker/Dockerfile.nextjs|node|python`, adapt build/start to the
   inventory (Railway start command / Procfile / package.json scripts), add one `ARG`+`ENV` per
   `NEXT_PUBLIC_*`/`VITE_*` variable, keep the RDS CA bundle lines, copy `dockerignore` to
   `.dockerignore`. Base images are pinned by digest on one `FROM <image>:<tag>@sha256:... AS base`
   line; to change the Node/Python version, change the tag and the digest together
   (`docker buildx imagetools inspect <image:tag>`). Copy `assets/github/dependabot.yml` to
   `.github/dependabot.yml` so the digest pins and the workflow actions get weekly update PRs.
   The Node/Next.js files have two targets: `runner` (what the service runs) and
   `tools` (full dependencies for migrations, built as `<sha>-tools`); the migration task uses the tools
   image because the standalone runner cannot run `payload migrate`, `drizzle-kit`, `prisma` or
   `auth migrate`. Build locally if Docker is available and fix what fails.
4. **Application changes**: apply the items `references/app-changes.md` prescribes for the detected
   flags, using `assets/app-snippets/` (health route, `next.config`, Payload adapters, Better Auth,
   webhook raw-body route, pg pool, maintenance proxy for the OLD deployment). Make the edits in the
   repo on a branch when you have it; otherwise list them as a precise checklist in PLAN.md.
5. **Secrets file**: write `migration/.secrets/aws.<env>.env.template` containing only `KEY=` lines for
   every `secret_keys` entry with a comment per key saying where the value comes from (provider
   dashboard, generated with `openssl rand -base64 32`, RDS output). The user fills it; then
   `scripts/put_secrets.sh --secret-name <project>-<env>/app --env-file ... --dry-run` then for real
   (the secrets module names the secret `<project>-<env>/app`, e.g. `lumen-prod/app`). In breach mode
   the fingerprint file sits in the same directory, so `put_secrets.sh` refuses exposed values by key
   name; `--allow-carryover KEY` only for a value the user confirms is not a secret. In breach mode the
   template's comments say "new value from <provider>" and never "copy from railway.<service>.env".
6. **Validate**: `terraform fmt -recursive`, `terraform init -backend=false && terraform validate` in
   every root you touched, `tflint`. Fix until clean. Run `scripts/estimate_cost.py` with the final
   knobs (`--kms`, `--worker-spot`, `--s3-gb`, `--efs-gb`, `--migration-host` as applicable) and paste
   the table into PLAN.md.
7. **Order of operations** goes in `migration/RUNBOOK.md` (next phase) and in the infra README:
   bootstrap (human, local state, then migrate state) -> activate cost-allocation tags a day later ->
   network -> project root first apply with `image_tag = "bootstrap"` and `traffic_target = "old"`
   (ECR exists, the service cannot pull yet: expected, and no public DNS changes) -> build and push
   `<sha>` and `<sha>-tools` -> `put_secrets.sh` -> create the DB roles -> run the migration task ->
   apply with the real tag -> smoke test on the ALB/CloudFront hostname via `/etc/hosts`. The deploy
   workflow repeats "build -> migrate (tools image, before anything changes) -> apply -> wait stable"
   on every push, mirroring Railway's pre-deploy command. Note that the SNS email subscription must
   be confirmed and that GitHub repo variables (role ARNs, region, `TF_ROOT`) must be set.

## Phase 4: Data

Read `references/data-migration.md`. Produce `migration/DATA.md` with the exact commands for this app:
source connection route (SSH tunnel preferred) and where the restore runs from (the optional
`migration_host`, SSM-only, inside the VPC; the RDS endpoint is private), `pg_migrate.sh preflight
--pg-major-check | audit | dump | roles | restore --target-db <db> --role app_owner | verify` (`audit`
is read-only and lists every role, function, trigger and foreign server the dump would carry; in breach
mode its signed-off report is required before the final dump), target DB/role
names, extension list and blockers (TimescaleDB, unsupported versions; PostGIS needs
`--exclude-table-data spatial_ref_sys`), the minimal-downtime decision (dump/restore under ~10 GB and
>= 15 min tolerance; native logical replication otherwise, with the `wal_level=logical` + RDS egress
prerequisites), file copy commands (`blob_to_s3.ts`: check `vercel blob list` first, Payload's Blob
adapter already stores pathnames as `<prefix>/<file>` so `S3_PREFIX` is usually empty;
`railway_bucket_to_s3.sh`; `railway_volume_to_s3.sh`), the stored-URL rewrite SQL, and the
verification steps. Insist on one rehearsal into a scratch database before cutover day.

## Phase 5: Runbook

Fill `references/cutover-runbook-template.md` into `migration/RUNBOOK.md` with this project's names,
hostnames, webhook/OAuth providers, DNS location and TTL plan, the rehearsal checklist, the minute-by-
minute cutover sequence, rollback triggers and the data-loss exposure, and the day-1 / day-7 / day-14
post-cutover tasks (rotation, decommissioning, cost verification). In breach mode, include the
template's breach-mode lines (session secrets at the cutover minute, the TCP proxy deleted before the
first rehearsal and gone by cutover, the Day 1 canary credential, `breach_check.sh --verify` before
decommissioning) and drop the Day 1-2 rotation items that already happened. The flip itself is two Terraform
variables in one apply: `traffic_target = "aws"` and `crons_enabled = true`; rollback is the reverse.
If DNS moves to Route 53, delegation happens at T-7 with `old_platform_records` still pointing at the
old site. The maintenance switch is cherry-picked onto the OLD deployment alone; the migration branch
(adapter swaps, S3 storage) must not reach the old platform. Every `<placeholder>` must be filled or
explicitly marked as a question for the user.

## Phase 6: Hand-over

Summarise in chat: what was generated and where, the three or four decisions that most affect cost and
risk, what the user must do by hand (fill secrets, bootstrap apply, DNS), and the open questions. Offer
to apply the application code changes on a branch if not done, and to review `terraform plan` output
when they have it (plans contain no secret values with this layout).

## Deliverables

```
<repo>/
  migration/
    inventory/   INVENTORY.md  CODEBASE.md  codebase.json  railway/  vercel/
    .secrets/    (git-ignored; written by scripts only)  aws.<env>.env.template
    PLAN.md      DATA.md      RUNBOOK.md
    BREACH.md    BREACH-CHECK.md   (breach mode only; fingerprints in .secrets/railway.burned.sha256)
  infra/         bootstrap/  network/  modules/  live/<project>/<env>/  Makefile  .tflint.hcl  ...
  .github/workflows/terraform.yml  deploy.yml
  .github/dependabot.yml
  Dockerfile  .dockerignore  (+ app code changes on a branch)
```

## Assets and references (read on demand)

| Need | File |
|---|---|
| Railway primitives, export commands, variable classes, DB template facts | `references/railway-inventory.md` |
| Vercel primitives, Secret-vs-Config, Blob, crons, ISR, Next 16 notes | `references/vercel-inventory.md` |
| Tiers, prices, compute/network/DB/edge decision matrices, cost narrative | `references/aws-target-architecture.md` |
| Layout, backend/state, secrets rules, image-tag ownership, CI, OpenTofu, pitfalls | `references/terraform-conventions.md` |
| Code changes per framework (Next.js, Payload, auth, ORMs, webhooks, Python, Shopify apps / third-party-registered URLs), CloudFront facts | `references/app-changes.md` |
| pg_dump/restore, logical replication, roles, Blob/bucket/volume copy, verification | `references/data-migration.md` |
| OIDC roles, isolation, secret handling, tags/budgets/anomalies, alarms, Organizations | `references/security-and-billing.md` |
| Runbook skeleton | `references/cutover-runbook-template.md` |
| Breach mode: fingerprint, BREACH.md, rotation order, session secrets after a leak (only when values were exposed) | `references/breach-response.md` |
| Terraform roots (`bootstrap`, `network`, `platform` for the shared tier, `live/example-app/prod`) and modules (`alb_https`, `ecs_service`, `rds_postgres`, `valkey`, `secrets`, `scheduled_task`, `s3_media`, `cloudfront_app`, `budget_alerts`, `github_oidc_roles`, `migration_host`), validated on Terraform 1.17 / AWS provider 6.70 | `assets/terraform/` |
| Dockerfiles (Next.js standalone, Node, Python) and `.dockerignore` | `assets/docker/` |
| App snippets (health route, next.config, Payload, Better Auth, Stripe route, pg pool, maintenance switch for Next.js and React Router/Remix) | `assets/app-snippets/` |
| GitHub Actions (plan/apply, build/deploy/migrate) | `assets/github-workflows/` |
| Scripts (prereqs, inventories, breach check, codebase scan, pg migrate + SQL, blob/bucket copy, put_secrets, cost) | `scripts/README.md` |

## Facts that commonly surprise people (keep them in mind)

- Railway `railway.json`/`toml` is deprecated (cutoff 2026-12-01); `.railway/railway.ts` and
  `railway config pull --include-variables` are the current source of truth.
- Vercel `env pull` writes placeholders for Secret-type variables; Railway sealed variables are gone for good.
- App Runner is closed to new customers; ECS Express Mode is AWS's replacement.
- EventBridge Scheduler cannot call HTTP URLs (Vercel-style crons need a rule + API destination or a RunTask).
- Fargate tasks in private subnets need NAT (~$33/mo) or ~$29-58/mo of VPC endpoints just to pull
  images; public-subnet tasks with strict security groups are the sane budget default.
- CloudFront strips headers that are not in the origin request policy: webhook signatures vanish
  unless `/api/*` forwards all viewer headers (the module does).
- `revalidateTag()` purges nothing on CloudFront; multi-task ISR needs a shared cache handler or a rethink.
- Cost allocation tags take up to 24 h to appear and are not retroactive; activate them on day one.
- GitHub OIDC subjects changed for repos created after 2026-07-15 (`repo:org@id/repo@id:...`);
  trust both forms. A job with `environment: prod` presents an `environment:prod` subject, so the
  root's `github_environment` must match the workflow or the first apply fails with AccessDenied.
  Required reviewers on Environments are Enterprise-only for private repos.
- Next.js standalone images cannot run migration CLIs; a `tools` image (or the same image for Python)
  runs them as a one-off ECS task before the service rolls, like Railway's pre-deploy command.
- Public ALB + CloudFront means the ALB hostname bypasses WAF; the module documents origin
  verification / VPC origins as the hardening step, call it out in the plan's risks.
- Terraform 1.11+ / OpenTofu 1.11+: native S3 locking (`use_lockfile`), write-only arguments; the
  generated code works on both.
