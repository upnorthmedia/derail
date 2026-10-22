# Railway inventory: project `Geo Gate Shopify` (<railway-project-id>) / environment `production`
Exported 2026-10-22 from the Railway API (describe-environment / describe-service). Variable NAMES only; no values were exported.
Workspace: Acme Studio. Region: us-west2 for everything.

## Services
| Service | Source | Builder | Start cmd | Healthcheck | Restart | Replicas | Cron | Volumes | Domains | TCP proxy |
|---|---|---|---|---|---|---|---|---|---|---|
| app | github acme-studio/geo-gate-shopify (main) | RAILPACK (no Dockerfile) | (Railpack default: `npm run start`) | none configured | ON_FAILURE (default) | 1 | - | - | app-production-1a2b.up.railway.app (Railway-provided; NO custom domain) | - |
| cron | same repo (Railpack) | RAILPACK | `npm run poll:subscriptions` | - | NEVER | 1 | `47 0 * * *` (UTC) | - | - | - |
| Postgres | image ghcr.io/railwayapp-templates/postgres-ssl:18 | image | - | - | - | 1 | - | postgres-volume -> /var/lib/postgresql/data (5000 MB, ~400 MB used) | - | none (private; the app uses the private DATABASE_URL) |

PgBouncer: disabled. HA: disabled. PITR: disabled. Private networking: app -> postgres.railway.internal:5432. Tracing: off. No buckets, no shared variables, no webhooks configured on Railway.

## Variables (names by class)
### app
- database: DATABASE_URL (reference -> ${{Postgres.DATABASE_URL}})
- config: SCOPES, SHOPIFY_APP_URL (= https://app-production-1a2b.up.railway.app), SHOPIFY_APP_GID, SHOPIFY_PARTNER_ORG_ID, REVIEWS_APP_ID
- app_secret: SHOPIFY_API_KEY, SHOPIFY_API_SECRET, SHOPIFY_PARTNER_API_TOKEN, REVIEWS_API_KEY
### cron
- database: DATABASE_URL
- config: SCOPES, SHOPIFY_APP_URL, SHOPIFY_APP_GID, SHOPIFY_PARTNER_ORG_ID
- app_secret: SHOPIFY_API_KEY, SHOPIFY_API_SECRET, SHOPIFY_PARTNER_API_TOKEN
### Postgres
- database: DATABASE_URL, PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE (db: railway); railway_injected: RAILWAY_PRIVATE_DOMAIN, RAILWAY_VOLUME_MOUNT_PATH; app_secret: POSTGRES_PASSWORD

## Context
Shopify App Store app (embedded admin app + checkout-time rules API + Shopify webhooks with HMAC). The app URL and OAuth redirect URLs registered with Shopify are the Railway-provided hostname (see shopify.app.toml). Installed on ~40 merchant stores. Low traffic (<50k requests/month), bursts at checkout. Usage last month: app ~$4.10, cron ~$0.05, Postgres ~$2.60 (Hobby plan $5).
