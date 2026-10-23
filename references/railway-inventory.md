# Railway inventory: what to discover, how to export it, where it goes on AWS

Facts verified against docs.railway.com on 2026-10-22. Railway changes fast; when a CLI flag below
fails, run `railway <cmd> --help` and save whatever JSON you can get. Always keep the raw output.

## Contents
1. Headline facts that change how you migrate
2. Discovery order and commands
3. Primitive-by-primitive mapping table
4. Variables: classes, references, sealed values, injected RAILWAY_* vars
5. Builds (Railpack/Nixpacks/Dockerfile) and the deprecated railway.json schema
6. Databases (Postgres template, HA, PgBouncer, PITR, Redis, MySQL, Mongo)
7. Things Railway does implicitly that AWS will not

## 1. Headline facts

- `railway.json` / `railway.toml` config-as-code is deprecated with a hard cutoff of **2026-12-01**.
  The replacement is `.railway/railway.ts` (Infrastructure as Code). Read both plus dashboard settings.
- **Best single export:** `railway config pull --force --include-variables` writes services, sources,
  build/start/healthcheck, replicas per region, env vars (with `${{...}}` references preserved),
  databases, volumes, buckets, custom domains and function source into `.railway/railway.ts`.
- **Sealed variables cannot be exported** by any CLI/API path (they render as `preserve()`). The
  migrator must re-issue those secrets from the provider. Treat the migration as a secret-rotation event.
- Builder enum is `RAILPACK` (default) | `DOCKERFILE`; Nixpacks is deprecated but still selectable.
  AWS has no Railpack, so a Dockerfile must be synthesized from the detected build plan.
- Databases are **private by default**; `DATABASE_PUBLIC_URL` exists only if "Public Access" (a TCP
  proxy) was added. `railway connect postgres --tunnel-only` opens an SSH tunnel for `pg_dump`
  without exposing anything.
- Railway Postgres may be fronted by **PgBouncer** or an **HA** HAProxy service; `DATABASE_URL` then
  points at the pooler, and `DATABASE_UNPOOLED_URL` at the node. Check with `railway postgres pgbouncer status --json`.
- Healthchecks on Railway are **deploy-gate only** (never continuous); restart policy default is
  `ON_FAILURE` x10; `drainingSeconds`/`overlapSeconds` default **0** (instant SIGKILL). No autoscaling.
- There are no log drains; logs are retained 7 d (Hobby) / 30 d (Pro). Webhooks exist but are unsigned.
- Pricing: Hobby $5/mo, Pro $20/mo (each includes that much usage); RAM $10/GB-mo and vCPU $20/vCPU-mo
  billed per minute on **actual** use; egress $0.05/GB; volumes $0.15/GB-mo; buckets $0.015/GB-mo with
  free egress. Fargate bills the **reserved** task size 24/7, so idle Railway apps cost more on AWS.

## 2. Discovery order and commands

`scripts/railway_inventory.sh --project <id|name> --environment production --out migration/inventory/railway`
runs all of this, saves raw JSON, writes variable VALUES only to `migration/.secrets/` (umask 077) and
produces `SUMMARY.md`. If you must do it by hand:

```bash
railway login --browserless                       # or RAILWAY_API_TOKEN / RAILWAY_TOKEN
railway list                                      # projects
railway link --project <id> --environment production
railway status --json                             # services, envs, volumes, functions, crons, regions, replicas
railway environment config --json
railway service list --json                       # 5.x; on CLI 4.x: railway service status --all --json
railway domain list --json; railway domain status <domain>
railway volume list --json; railway bucket list --json; railway bucket info --json -b <name>
railway functions list; railway cron list
railway private-network status; railway outbound-network status; railway cdn status
railway postgres ha status --json; railway postgres pgbouncer status --json; railway postgres pitr status --json
railway usage projects --project <name> --json    # per-service cost: the "before" column
railway variable list -s <service> -e production --json   # resolved values; sealed omitted
railway config pull --force --include-variables   # .railway/railway.ts (+ .railway/functions/*.ts)
railway logs --since 7d --json > logs.ndjson; railway logs --http --since 7d --json > http.ndjson
railway api 'query($id:String!){ project(id:$id){ name services{edges{node{id name}}} } }' --var id=<project-id>
```

If the Railway MCP server is connected, `list-projects`, `describe-environment`, `describe-service`,
`get-service-config`, `list-variables` (names only for OAuth connections), `list-domains`,
`list-tcp-proxies`, `list-webhooks`, `get-service-metrics` give the same inventory without the CLI.

Also grep the codebase for `up.railway.app`, `railway.internal`, `proxy.rlwy.net`, `storageapi.dev`,
`RAILWAY_` (scripts/scan_codebase.py does this).

## 3. Primitive mapping

| Railway | Discover / export | AWS equivalent | Gotchas |
|---|---|---|---|
| Project / environment | `railway status --json`, `environment list` | One Terraform root per project per env (`live/<project>/<env>`) | Each env has its own variables, domains, volumes. PR environments have no cheap equivalent; use one staging root. |
| Service from GitHub repo | `config pull` -> `source: github(...)`; builder in service settings | ECR image built by GitHub Actions (deploy.yml) + ECS Fargate service | Root directory for monorepos becomes the Docker build context. |
| Service from Docker image | `source: image("...")` | Same image in ECS task definition (pull-through cache optional) | Private registries: push to ECR. |
| Web service (has a domain, listens on PORT) | `railway domain list` | `ecs_service` module with `expose_http = true` behind `alb_https` | Set `PORT` explicitly; ALB target port = container port. |
| Worker (no domain) | service with no domains and no PORT use | `ecs_service` with `expose_http = false` (`enable_worker` in the root) | Railway has no healthcheck for workers; ECS can use a container command check. |
| Cron service (`cronSchedule`) | `railway cron list`; `cronSchedule` in config | `scheduled_task` module (EventBridge Scheduler -> RunTask) | Railway cron is 5-field UTC and skips overlapping runs; EventBridge is 6-field and does not skip; add a lock if runs can overlap. |
| Pre-deploy command (migrations) | `preDeployCommand` | One-off `aws ecs run-task` step in deploy.yml before the new tasks roll out | Same ordering guarantee must be rebuilt in CI. |
| Replicas / regions | `replicas` map, `numReplicas` | `desired_count` + autoscaling min/max; multi-region is out of scope | Right-size from `railway metrics` p95 CPU/mem (Railway bills usage, Fargate bills reservation). |
| Serverless (app sleeping) | `sleepApplication` / Settings -> Serverless | No Fargate equivalent; note the idle-cost delta (~$8-15/mo per smallest task) | OpenNext/Lambda if scale-to-zero matters. |
| Healthcheck path/timeout | `healthcheckPath`, `healthcheckTimeout` | ALB target group health check + ECS circuit breaker (continuous!) | Flapping endpoints get tasks restarted on AWS, never on Railway. |
| Restart policy | `restartPolicyType` | ECS always replaces stopped tasks; circuit breaker caps retries | `NEVER` + exits = one-off job -> RunTask. |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` / `OVERLAP_SECONDS` | variables | ECS `stopTimeout` (30 s default) and `minimumHealthyPercent` | Apps tuned for instant SIGKILL get more grace on AWS. |
| Private networking (`<svc>.railway.internal`, IPv6 on older envs) | `private-network status` | VPC + security groups; ECS Service Connect / Cloud Map if services call each other | Railway has no port-less discovery; apps that bind `::` for IPv6 are fine. |
| Public domain + auto TLS | `railway domain list` | ALB + ACM (DNS-validated) + Route 53; CloudFront optional | Find hard-coded `up.railway.app` URLs in CORS/OAuth/webhooks. |
| Custom domain | `domain list` (CNAME + TXT verification) | Route 53 alias record + ACM | Apex domains work natively on Route 53 alias. |
| TCP proxy (`*.proxy.rlwy.net:<port>`) | `tcpProxies` GraphQL / MCP `list-tcp-proxies` | NLB, or nothing (databases stay private on AWS) | Remove the proxy after migration. |
| Static outbound IPs | `outbound-network status` | NAT Gateway EIP | Update third-party allow-lists. |
| CDN / edge rules / WAF under-attack | `cdn status`; Settings -> Edge (export JSON ruleset) | CloudFront cache policies; AWS WAF rules | Export the ruleset JSON verbatim before deleting anything. |
| Volume | `volume list --json`; data via `railway volume files download / ./dump` or `scp <svc>@ssh.railway.com:/mnt/..` | S3 (uploads), EFS (only when files must be read back by path), RDS (database volumes) | Volume backups cannot be downloaded; export the data itself. |
| Bucket (S3-compatible on Tigris) | `bucket list`, `bucket credentials` prints `AWS_*` vars | S3 + CloudFront OAC | `scripts/railway_bucket_to_s3.sh`; no versioning/lifecycle on Railway so nothing to carry over. |
| Postgres / MySQL / Redis / Mongo templates | `variable list -s <db>` | RDS PostgreSQL / RDS MySQL / ElastiCache Valkey / DocumentDB or Atlas | See section 6. |
| Shared variables, reference variables | `config pull` keeps references | Plain env + Secrets Manager; references are resolved by hand | Every `${{Postgres.*}}` consumer must be re-pointed at RDS. |
| Sealed variables | names only | Secrets Manager | Re-issue the secret from its provider. |
| Functions (single-file TS on Bun) | `functions list`; `config pull` decodes source | Lambda (Node runtime) or a tiny ECS service | Bare `import {Hono} from "hono@4"` needs a package.json. |
| Webhooks (deploy status, CPU/RAM/volume alerts) | Project Settings -> Webhooks | EventBridge rules on ECS events -> SNS; CloudWatch alarms | Thresholds must be recreated. |
| Tracing (OTEL vars injected) | `trace status --all` | ADOT sidecar / X-Ray | Set `OTEL_EXPORTER_OTLP_ENDPOINT` yourself. |
| Logs | `railway logs --json` | CloudWatch Logs (`awslogs` driver) | Export history before deleting the project if it matters. |

## 4. Variables

Classes to assign to every variable name (the inventory script does this):

| Class | Examples | Action |
|---|---|---|
| Railway-injected | `PORT`, `RAILWAY_PUBLIC_DOMAIN`, `RAILWAY_PRIVATE_DOMAIN`, `RAILWAY_ENVIRONMENT_NAME`, `RAILWAY_GIT_COMMIT_SHA`, `OTEL_*` | Do not copy. Provide equivalents (`PORT`, `APP_URL`, `GIT_SHA`) in `plain_env` / build args. |
| Build tuning | `RAILPACK_*`, `NIXPACKS_*`, `NO_CACHE` | Encode in the Dockerfile; do not copy. |
| Database URLs | `DATABASE_URL`, `DATABASE_PUBLIC_URL`, `DATABASE_UNPOOLED_URL`, `PG*`, `REDIS_URL`, `MYSQL_URL`, `MONGO_URL` | Replace with the RDS/ElastiCache endpoints and the new app-user password; store in the app secret. |
| Bucket credentials | `BUCKET`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `ENDPOINT`, `REGION=auto` | Replace with `S3_BUCKET` + task-role credentials (no keys). |
| Reference-looking | values containing `${{` | Resolve the graph; the resolved value is in `variable list` output. |
| Sealed / missing | present in dashboard, absent from export | Re-issue from provider; list them explicitly in the plan. |
| App secret | API keys, tokens, `*_SECRET`, `*_KEY`, `*_PASSWORD`, `*_TOKEN`, URLs with credentials | `secret_keys` in Terraform + `scripts/put_secrets.sh`. |
| Plain config | feature flags, public URLs, `NODE_ENV`, locale | `plain_env` in Terraform (visible in the task definition). |
| Build-time public | `NEXT_PUBLIC_*`, `VITE_*`, `REACT_APP_*` | Docker build args (inlined at build), not runtime secrets. |

Railway makes all service variables available at build time too; on AWS, build-time values must be
passed as build args or BuildKit secrets explicitly.

## 5. Builds and the deprecated config-as-code schema

Deprecated `railway.json` (TOML equivalent uses `[build]`, `[deploy]`, `[environments.<name>.deploy]`):

```jsonc
{
  "build":  { "builder": "RAILPACK", "buildCommand": "...", "watchPatterns": ["src/**"], "dockerfilePath": "Dockerfile.backend" },
  "deploy": { "startCommand": "node index.js", "preDeployCommand": ["npm run db:migrate"],
              "healthcheckPath": "/health", "healthcheckTimeout": 300,
              "restartPolicyType": "ON_FAILURE", "restartPolicyMaxRetries": 10,
              "cronSchedule": "*/15 * * * *", "multiRegionConfig": { "us-west2": { "numReplicas": 2 } },
              "overlapSeconds": "60", "drainingSeconds": "10" },
  "environments": { "staging": { "deploy": { "startCommand": "npm run staging" } } }
}
```

Mapping to the generated assets: `startCommand` -> Dockerfile `CMD` (or `container_command`);
`buildCommand` -> Dockerfile build stage; `healthcheckPath` -> `health_check_path`; `cronSchedule` ->
`cron_jobs`; `preDeployCommand` -> migration RunTask step in deploy.yml; `numReplicas` -> `desired_count`.

Railpack/Nixpacks detection to replicate in the Dockerfile: language version from `.nvmrc`, `engines`,
`.python-version`, `runtime.txt`, `go.mod`; install from the lockfile; build from the `build` script;
start from `startCommand`, `Procfile` `web:`, or the `start` script. Railway Dockerfiles may contain
`--mount=type=cache,id=s/<service-id>-...` cache mounts: strip the Railway-specific `id=`.

## 6. Databases

**Postgres template** (`ghcr.io/railwayapp-templates/postgres-ssl:<major>`): official image plus a
self-signed cert (SAN `localhost` + private domain), `max_connections=500`, `pg_stat_statements`
preloaded, default DB `railway`, user `postgres` (a real superuser). Clients use `sslmode=require`;
`verify-full` cannot work against Railway, but **must** be used against RDS (bundle at
`https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem`). Apps that set
`rejectUnauthorized: false` for Railway should be tightened.

**Dump routes** (prefer A):
```bash
# A: SSH tunnel, no public exposure, no egress billing
railway connect postgres --tunnel-only      # prints local host/port/user/password; keep it open
SRC_URL='postgresql://postgres:<pw>@localhost:<port>/railway' scripts/pg_migrate.sh dump
# B: public TCP proxy (needs Public Access; egress $0.05/GB)
SRC_URL="$DATABASE_PUBLIC_URL" scripts/pg_migrate.sh dump
```

**PgBouncer** (transaction mode, pool 20, 1000 clients per replica): a Vercel app pointed at
`DATABASE_PUBLIC_URL` is probably already going through PgBouncer. On AWS the default is direct RDS
with a driver pool of ~10 per task; RDS Proxy costs ~$22/mo minimum and is unnecessary at this scale.

**HA** (Patroni + HAProxy): dump through `DATABASE_URL` (routes to the primary). **PITR**: nothing to
export; RDS has native PITR. **Redis**: password auth, usually no TLS (`redis://`); ElastiCache uses
TLS (`rediss://`) so clients must support it. **MySQL**: `mysqldump --single-transaction` via tunnel.
**Mongo**: `mongodump` via tunnel; DocumentDB lacks some operators, test or use Atlas on AWS.

Extensions: the Railway image ships only `contrib`; RDS PG 18 has pgvector 0.8.2, PostGIS 3.6,
pg_trgm, uuid-ossp, pg_cron (needs a parameter group). TimescaleDB is **not** on RDS.

## 7. What Railway did for you that AWS will not (tell the user)

Automatic TLS and HTTP->HTTPS; `PORT` injection and port detection; zero-config private DNS with free
internal traffic; reference variables that stay in sync; restart-on-crash with a healthcheck gate;
builds from source with free build minutes and caching; build-time secrets; PR environments; one-click
environment duplication; scale-to-zero and per-minute usage billing; cron overlap skipping; pre-deploy
commands; log/HTTP/DNS/flow logs in one place; metrics and an OTLP receiver; volume backups and DB
PITR/HA/PgBouncer toggles; a free CDN, edge rules, WAF under-attack mode; static outbound IPs on Pro;
deploy webhooks; hard usage limits; SSH/SFTP into containers (AWS: ECS Exec, no SFTP).

The generated Terraform covers TLS, health checks, circuit-breaker rollback, alarms, budgets,
backups, logs and secrets. It does not cover PR environments, scale-to-zero, or multi-region.
