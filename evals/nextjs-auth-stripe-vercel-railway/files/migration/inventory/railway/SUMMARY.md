# Railway inventory: project `pawbook` / environment `production` (workspace: Acme Studio)
Exported 2026-10-22. Variable VALUES are in migration/.secrets/ (not included here).

## Services
| Service | Source | Replicas | Region | Volumes | TCP proxy |
|---|---|---|---|---|---|
| Postgres-7Kq2 | image ghcr.io/railwayapp-templates/postgres-ssl:18 | 1 | us-west2 | postgres-volume-x9Pz -> /var/lib/postgresql/data (5000 MB, ~3.8 GB used) | yes (public access; Vercel connects through it) |

No app services on Railway. PgBouncer: disabled. HA: disabled. PITR: disabled. Daily volume backups.
Extensions in use (from psql): plpgsql, pgcrypto, pg_trgm, postgis 3.5 (geo search for groomers).

## Variables (names by class)
### Postgres-7Kq2
- database: DATABASE_URL, DATABASE_PUBLIC_URL, PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE (db name: railway)
- railway_injected: RAILWAY_PRIVATE_DOMAIN, RAILWAY_TCP_PROXY_DOMAIN, RAILWAY_TCP_PROXY_PORT, RAILWAY_VOLUME_MOUNT_PATH
- app_secret: POSTGRES_PASSWORD

## Usage (previous period)
Postgres ~$6.80/mo (RAM 0.6 GB avg, CPU 0.12 vCPU avg, volume 5 GB), TCP proxy egress ~$1.10/mo. Hobby plan $5/mo.
