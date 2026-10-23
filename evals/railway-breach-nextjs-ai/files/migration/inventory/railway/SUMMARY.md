# Railway inventory: project `quillnote` / environment `production` (workspace: Quillnote)
Exported 2026-10-22 (after the AI keys were rotated). Variable VALUES are in migration/.secrets/ on the
founder's laptop (not included here). Plan: Pro ($20/mo).

## Services
| Service | Source | Builder | Start cmd | Healthcheck | Replicas | Region | Cron | Volumes | Domains | TCP proxy |
|---|---|---|---|---|---|---|---|---|---|---|
| web | github quillnote/quillnote (branch main, root /) | RAILPACK | pnpm start | /api/health (60 s) | 2 | us-east4-eqdc4a | - | - | quillnote.example (custom), web-production-9c1d.up.railway.app | - |
| worker | github quillnote/quillnote (same repo) | RAILPACK | pnpm worker | - | 1 | us-east4-eqdc4a | - | - | - | - |
| Postgres | image ghcr.io/railwayapp-templates/postgres-ssl:17 | image | - | - | 1 | us-east4-eqdc4a | - | postgres-volume -> /var/lib/postgresql/data (10 GB, 3.1 GB used) | - | **yes**: maglev.proxy.rlwy.net:41234 (public, used for local dumps) |

Pre-deploy command on `web`: `pnpm db:migrate`. Private networking: web/worker -> postgres.railway.internal:5432.
Serverless/sleeping: off. PITR: off. Extensions: plpgsql, pgcrypto, pg-boss schema `pgboss`.
CI: GitHub Actions deploys with `railway up` using a `RAILWAY_TOKEN` stored in GitHub repository secrets.

## Variables (names by class)
### web
- reference: DATABASE_URL (-> ${{Postgres.DATABASE_URL}})
- app_secret: BETTER_AUTH_SECRET, GITHUB_CLIENT_SECRET, OPENAI_API_KEY, ANTHROPIC_API_KEY, STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET
- bucket_credential: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION (static IAM user keys for the existing S3 bucket `quillnote-uploads`, us-east-1)
- plain: BETTER_AUTH_URL, GITHUB_CLIENT_ID, S3_BUCKET, PORT=3000
- public_buildtime: NEXT_PUBLIC_APP_URL
- railway_injected: RAILWAY_PUBLIC_DOMAIN, RAILWAY_PRIVATE_DOMAIN
### worker
- reference: DATABASE_URL (-> ${{Postgres.DATABASE_URL}}), OPENAI_API_KEY (-> ${{web.OPENAI_API_KEY}}), ANTHROPIC_API_KEY (-> ${{web.ANTHROPIC_API_KEY}})
- sealed_unavailable: RESEND_API_KEY (sealed)
### Postgres
- database: DATABASE_URL, DATABASE_PUBLIC_URL, PGPASSWORD, POSTGRES_PASSWORD, PGUSER, PGDATABASE, PGHOST, PGPORT

## Usage (previous period)
web 2 replicas ~$22/mo, worker ~$9/mo, Postgres ~$6/mo + volume $2.50, egress ~$3. Total ~$43/mo + $20 plan.
