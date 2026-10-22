# Railway inventory: project `docflow` / environment `production` (workspace: Docflow GmbH)
Exported 2026-10-22. Variable VALUES are in migration/.secrets/ (not included here). Plan: Pro ($20/mo).

## Services
| Service | Source | Builder | Start cmd | Healthcheck | Replicas | Region | Cron | Volumes | Domains | TCP proxy |
|---|---|---|---|---|---|---|---|---|---|---|
| api | github docflow/api (branch main, root /) | DOCKERFILE | uvicorn app.main:app --host :: --port $PORT --workers 2 | /healthz (120 s) | 2 | europe-west4-drams3a | - | docs-data -> /data (20 GB, 11 GB used) | api.docflow.example (custom), api-production-1a2b.up.railway.app | - |
| worker | github docflow/api (same repo) | DOCKERFILE | celery -A app.worker.celery worker --concurrency 2 | - | 1 | europe-west4-drams3a | - | docs-data (same volume? NO: Railway allows one service per volume; worker reads files over HTTP from api) | - | - |
| nightly-report | github docflow/api | DOCKERFILE | python -m app.nightly | - | 1 | europe-west4-drams3a | 0 3 * * * | - | - | - |
| Postgres | image ghcr.io/railwayapp-templates/postgres-ssl:16 | image | - | - | 1 | europe-west4-drams3a | - | postgres-volume -> /var/lib/postgresql/data (50 GB, 18 GB used) | - | no (private only) |
| Redis | image redis:7 (Railway template) | image | - | - | 1 | europe-west4-drams3a | - | redis-data -> /data (1 GB) | - | no |

Pre-deploy command on `api`: `alembic upgrade head`. Private networking in use: api -> postgres.railway.internal:5432, api/worker -> redis.railway.internal:6379. Static outbound IPs: enabled (an upstream bank API allow-lists them). Serverless/sleeping: off. Deployment draining seconds: 30. PITR: enabled on Postgres. Extensions: plpgsql, pg_trgm, uuid-ossp, pgvector 0.8.

## Variables (names by class)
### api
- database: DATABASE_URL (-> ${{Postgres.DATABASE_URL}}), REDIS_URL (-> ${{Redis.REDIS_URL}})
- app_secret: JWT_SECRET, POSTMARK_SERVER_TOKEN, BANK_API_KEY, SENTRY_DSN
- plain: UPLOAD_DIR=/data/uploads, ALLOWED_ORIGINS, LOG_LEVEL, PORT=8000
- railway_injected: RAILWAY_PUBLIC_DOMAIN, RAILWAY_PRIVATE_DOMAIN, RAILWAY_VOLUME_MOUNT_PATH, RAILWAY_DEPLOYMENT_DRAINING_SECONDS
- sealed_unavailable: BANK_API_KEY (sealed)
### worker
- database: DATABASE_URL, REDIS_URL (references)
- app_secret: SENTRY_DSN; shared: ${{shared.SENTRY_DSN}}
### nightly-report
- database: DATABASE_URL; app_secret: POSTMARK_SERVER_TOKEN

## Usage (previous period)
api 2 replicas ~$31/mo, worker ~$14/mo, nightly ~$0.30/mo, Postgres ~$9/mo + volume $7.50, Redis ~$2/mo, volumes (docs 20 GB) $3, egress ~$6. Total ~$73/mo + $20 plan.
