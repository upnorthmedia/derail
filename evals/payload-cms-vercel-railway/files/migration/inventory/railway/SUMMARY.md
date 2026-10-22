# Railway inventory: project `lumen` / environment `production` (workspace: Acme Studio)
Exported 2026-10-22 with railway CLI. Variable VALUES are in migration/.secrets/ (not included here).

## Services
| Service | Source | Builder | Start cmd | Healthcheck | Replicas | Region | Cron | Volumes | Domains | TCP proxy |
|---|---|---|---|---|---|---|---|---|---|---|
| Postgres | image ghcr.io/railwayapp-templates/postgres-ssl:18 | DOCKERFILE (image) | (image default) | - | 1 | us-west2 | - | postgres-volume -> /var/lib/postgresql/data (5000 MB, ~2.1 GB used) | - | yes (public access enabled, used by Vercel) |
| PgBouncer | image ghcr.io/railwayapp-templates/pgbouncer:1 | DOCKERFILE (image) | (image default) | - | 3 | us-west2 | - | - | - | yes |

No app services on Railway (the Next.js app is on Vercel). `railway postgres pgbouncer status`: enabled, pool_mode=transaction, DEFAULT_POOL_SIZE=20, MAX_CLIENT_CONN=1000. HA: disabled. PITR: disabled. Volume backups: daily (6 kept).

## Variables (names by class)
### Postgres
- database: DATABASE_URL, DATABASE_PUBLIC_URL, DATABASE_UNPOOLED_URL, DATABASE_PUBLIC_UNPOOLED_URL, PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE (db name: railway)
- railway_injected: RAILWAY_PRIVATE_DOMAIN, RAILWAY_TCP_PROXY_DOMAIN, RAILWAY_TCP_PROXY_PORT, RAILWAY_VOLUME_MOUNT_PATH
- app_secret: POSTGRES_PASSWORD, SSL_CERT_DAYS
### PgBouncer
- reference: DATABASE_URL (-> ${{Postgres.DATABASE_URL}}), POOL_MODE, DEFAULT_POOL_SIZE, MAX_CLIENT_CONN

## Usage (previous period)
Postgres ~$3.10/mo (RAM 0.3 GB avg, CPU 0.05 vCPU avg, volume 5 GB), PgBouncer 3 replicas ~$4.20/mo, egress via TCP proxy ~$0.40/mo. Hobby plan $5/mo.
