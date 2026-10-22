# Application code changes by framework

What must change in the app itself so it runs on ECS Fargate behind an ALB (and optionally
CloudFront). Snippets live in `assets/app-snippets/`. `scripts/scan_codebase.py` flags which of these
apply to a given repo.

## Contents
1. Every app
2. Next.js
3. Payload CMS
4. Auth libraries (Better Auth, NextAuth/Auth.js, Clerk)
5. ORMs and database drivers (Prisma, Drizzle, node-postgres, Django/SQLAlchemy)
6. Webhooks (Stripe, Twilio, Resend/Svix, Typeform)
7. Python / generic Node services
8. CloudFront + ALB header and caching facts

## 1. Every app

- **Listen on `0.0.0.0:$PORT`.** Railway injected `PORT`; the task definition sets it explicitly
  (default 3000). Apps that read `process.env.PORT` with no fallback are fine; apps that bind
  `localhost` are not reachable by the ALB.
- **Health endpoint** at `health_check_path` (default `/api/health`): 200, no auth, no DB call
  (`assets/app-snippets/nextjs/app/api/health/route.ts`). The ALB probes it every 15-30 s and ECS
  restarts tasks that fail; a DB-dependent probe turns a slow query into an outage.
- **Graceful shutdown**: handle SIGTERM (ECS `stopTimeout` 30 s; Railway's default was 0 s, so this
  is new headroom). `tini` is PID 1 in the Dockerfiles.
- **Build-time vs runtime config**: `NEXT_PUBLIC_*`, `VITE_*`, `REACT_APP_*` are inlined at build. Pass
  them as Docker `--build-arg`; everything else comes from the task definition (`plain_env`) or the app
  secret at runtime. Railway made all variables available at build time, which hid this distinction.
- **Absolute URLs**: replace `RAILWAY_PUBLIC_DOMAIN` / `VERCEL_URL` / `VERCEL_PROJECT_PRODUCTION_URL` with
  one `APP_URL` (or `NEXT_PUBLIC_SERVER_URL`) you set.
- **Trust the proxy**: the ALB sets `X-Forwarded-For/Proto/Port`; CloudFront adds a hop. Configure the
  framework's trusted-proxy setting so `req.ip`, `secure` cookies and `https` redirects behave.
- **TLS to the database**: RDS PostgreSQL 15+ enforces TLS (`rds.force_ssl=1`). Use
  `sslmode=verify-full` with the RDS CA bundle baked into the image
  (`ADD https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /app/global-bundle.pem`).
  Remove `rejectUnauthorized: false` / `sslmode=no-verify` hacks that were needed for Railway's self-signed cert.
- **Connection pool**: ~10 connections per task; drop `?pgbouncer=true` and `DIRECT_URL` splits.
- **Object storage**: use the task role (no access keys). Any SDK call to Railway buckets
  (`t3.storageapi.dev`) or Vercel Blob must point at S3.
- **Hard-coded hosts**: `up.railway.app`, `railway.internal:<port>`, `proxy.rlwy.net`, `vercel.app`,
  `blob.vercel-storage.com` in code, CORS lists, OAuth callbacks, email templates, DB rows.
- **Logging**: stdout/stderr JSON is captured by CloudWatch; no agent needed. Remove Vector/Fluent Bit
  sidecar services that existed only because Railway had no log drains.

## 2. Next.js (15.5.x or 16.4.x; pin the latest patch, sharp >= 0.35.5)

Checklist (`assets/app-snippets/nextjs/next.config.ts`):

1. `output: 'standalone'`; the Dockerfile copies `.next/standalone`, `.next/static`, `public`.
2. `deploymentId: process.env.GIT_SHA` so rolling deploys do not mix assets between builds; set
   `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` to one value per build when running more than one task.
3. Convert `export const runtime = 'edge'` routes to Node (delete the export). Next 16: `middleware.ts`
   -> `proxy.ts`.
4. Replace `@vercel/functions` helpers: `geolocation()`/`ipAddress()` -> CloudFront headers
   (`CloudFront-Viewer-Country`, `CloudFront-Viewer-Address`, forwarded by the AllViewer policy) or
   `X-Forwarded-For`; `waitUntil()` -> `after()` from `next/server`. Remove `@vercel/analytics`,
   `@vercel/speed-insights`.
5. `images.remotePatterns`: add the media CDN host (and the old Blob host during overlap).
6. ISR: choose `force-dynamic` + CloudFront `s-maxage`, a shared cache handler on Valkey, or
   OpenNext (`assets/app-snippets/nextjs/cache-handler.md`). `revalidateTag()` never purges CloudFront.
7. `compress: false` when CloudFront is in front (it compresses at the edge); `true` otherwise.
8. Port `vercel.json` `rewrites/redirects/headers` into `next.config`; crons into `cron_jobs`.
9. Add `app/api/health/route.ts`; add the maintenance `proxy.ts` to the OLD deployment before cutover.
10. If `next build` needs the database (Payload), pass `DATABASE_URL` as a BuildKit secret in CI.
11. Memory: `next build` for Payload admin wants 4-6 GB (`NODE_OPTIONS=--max-old-space-size`); the
    runtime task is fine at 1-2 GB.

## 3. Payload CMS 3.x (`assets/app-snippets/payload/payload.config.snippet.ts`)

- `@payloadcms/db-vercel-postgres` -> `@payloadcms/db-postgres` (`pool: { connectionString, max: 10, ssl }`, `push: false`).
- `@payloadcms/storage-vercel-blob` -> `@payloadcms/storage-s3` with `collections.media.prefix` equal to
  the Blob path prefix you copied, `config: { region }` (no credentials: task role),
  `generateFileURL` pointing at the CloudFront media host, `disablePayloadAccessControl: true` for public
  media. The adapter builds URLs as `${endpoint}/${bucket}/${prefix}/${filename}` if you skip `generateFileURL`.
- Run `payload migrate` as a one-off ECS task before new tasks roll out (deploy.yml `RUN_MIGRATIONS`,
  `migration_command = ["npx","payload","migrate"]`); it runs from the **tools** image
  (`Dockerfile.nextjs --target tools`, full `node_modules` + source) because the standalone runner has
  no CLI and no migration sources; never from two tasks at once; keep `push: false` in production.
  Same for Drizzle (`npx drizzle-kit migrate`), Prisma (`npx prisma migrate deploy`) and Better Auth
  (`npx auth@latest migrate`). Python images contain everything already: `tools_image_tag_suffix = ""`.
- Keep `PAYLOAD_SECRET` identical through cutover (sessions and encrypted fields depend on it).
- Rewrite stored Blob URLs in `media.url`, `sizes_*_url` and rich-text JSON after the final restore
  (data-migration.md section 5).
- `serverURL` = public https URL; WAF body-size rules on `/admin*` are set to count, not block.

## 4. Auth

- **Better Auth 1.7** (`assets/app-snippets/better-auth/auth.snippet.ts`): set `BETTER_AUTH_URL`
  explicitly; `advanced.trustedProxyHeaders` / `ipAddress.ipAddressHeaders` for the real client IP;
  cookies are Secure + httpOnly in production automatically; schema via `npx auth@latest migrate` from a
  one-off task; update OAuth redirect URIs in Google/GitHub consoles (dual-register before cutover).
- **NextAuth / Auth.js**: `NEXTAUTH_URL`/`AUTH_URL` = public URL, `AUTH_TRUST_HOST=true` behind a proxy,
  keep `AUTH_SECRET` identical through cutover.
- **Clerk / Auth0 / Supabase Auth**: add the new domain in the provider dashboard; nothing else.

## 5. ORMs and drivers (`assets/app-snippets/db/pg-pool.ts`)

- **Prisma 6**: `DATABASE_URL=...?sslmode=verify-full&sslrootcert=/app/global-bundle.pem&connection_limit=10`;
  remove `pgbouncer=true` and `directUrl`. Prisma 7 with `PrismaPg` adapter: pool `max: 10`.
- **Drizzle**: `drizzle({ client: new Pool({ connectionString, max: 10, ssl }) })`.
- **node-postgres**: `ssl: { ca, rejectUnauthorized: true }`.
- **Django**: `OPTIONS: {"sslmode": "verify-full", "sslrootcert": "/app/global-bundle.pem"}`, `CONN_MAX_AGE`.
- **SQLAlchemy / psycopg**: `?sslmode=verify-full&sslrootcert=...`, `pool_size=5`.
- Session-level features (LISTEN/NOTIFY, advisory locks, `SET`) work again on direct RDS; they were
  silently broken under Railway PgBouncer transaction mode.
- **Celery / BullMQ / RQ on ElastiCache**: use the node-based Valkey module with cluster mode disabled
  (Serverless is cluster-mode and breaks kombu/BullMQ with CROSSSLOT errors), `maxmemory-policy
  noeviction`, `rediss://` with `ssl_cert_reqs=required`; set `task_acks_late`/`prefetch 1` and a
  longer worker `stop_timeout` so in-flight jobs survive Fargate deploys.
- Migrations run as the migration role (owner), not the runtime role (`scripts/sql/app_roles.sql.tpl`).

## 6. Webhooks (`assets/app-snippets/webhooks/stripe-route.ts`)

- Read the raw body (`await req.text()`) and verify the signature; unchanged from Vercel.
- CloudFront strips headers not in the origin request policy; the `/api/*` behavior uses `AllViewer`
  so `stripe-signature`, `svix-*`, `X-Twilio-Signature`, `Typeform-Signature` arrive. Keep that if you edit policies.
- Twilio signs the full public URL: construct it from `APP_URL` + path, not `req.url`.
- Return 2xx within 30 s (Stripe) and under CloudFront's 60 s origin timeout; queue heavy work.
- Dual-register new endpoints before cutover where the provider allows (Stripe gives a new signing
  secret per endpoint -> new `STRIPE_WEBHOOK_SECRET` value on AWS); flip single-endpoint providers
  (Twilio numbers, Typeform) at cutover.

## 7. Python and generic Node services

- `assets/docker/Dockerfile.python` (uv or pip, uvicorn/gunicorn, non-root, tini) and
  `Dockerfile.node`. Replace Railpack's detected build/start with explicit `RUN`/`CMD`.
- Celery/RQ/BullMQ workers: `enable_worker = true`, `worker_command = ["celery", "-A", "app", "worker"]`;
  the broker becomes ElastiCache Valkey (`rediss://` + AUTH) or SQS.
- Django `ALLOWED_HOSTS` = public domain (+ ALB DNS name if you probe it directly),
  `SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")`, `CSRF_TRUSTED_ORIGINS`.
- Static files: WhiteNoise behind CloudFront, or S3 + CloudFront.

## 8. CloudFront + ALB facts that bite

- The ALB certificate must cover the origin hostname CloudFront connects to; the generated root creates
  `origin.<domain>` for that and forwards the viewer `Host` so the app sees the public host.
- Default behavior: managed cache policy `UseOriginCacheControlHeaders-QueryStrings` (keys on Host,
  cookies, all query strings incl. `_rsc`; honors `s-maxage`/`private`) + `AllViewer` origin request
  policy. Dynamic pages (`private, no-store`) are never cached; ISR/static pages are.
- `/_next/static/*`: CachingOptimized, immutable. `/_next/image*`: keyed on `url,w,q` + `Accept`.
- CloudFront origin response timeout max 60 s; ALB idle timeout default 60 s (raise for long streams).
- WAF is attached to the distribution, not the ALB; the ALB stays public unless you upgrade to a VPC
  origin (CloudFront Business plan or PAYG) or add origin verification (documented as hardening).

## 9. Apps whose public URL is registered with a third party (Shopify apps, OAuth callbacks, bots)

Some apps have no "DNS flip": the thing that sends traffic is a configuration held by someone else
(Shopify app URL and redirect URLs, Slack/Discord bot endpoints, a payment provider's callback URL, an
IdP's OAuth client). Often they only ever had the platform-provided hostname (`*.up.railway.app`,
`*.vercel.app`), which cannot be moved. Adjust the plan:

- Give the app a **custom hostname you own** on AWS (`app.<yourdomain>`), even if it never had one.
  Register the new URL with the third party *in addition* to the old one where the provider allows
  multiple values (OAuth redirect lists), and switch the primary at cutover.
- `traffic_target = "aws"` can be set **early** (T-3): a new hostname carries no traffic until the
  third party points at it, and you need the real TLS certificate to smoke-test an embedded/iframe app.
  Non-negotiable 7 still holds for whatever currently receives traffic; the switch is the third-party
  config change, and its rollback is reverting that change (keep the old deployment running meanwhile).
- There is usually no maintenance middleware you can deploy on the old platform in time; freeze writes
  at the database (`ALTER DATABASE ... SET default_transaction_read_only = on`) for the final dump instead.

**Shopify apps** (React Router/Remix template, `@shopify/shopify-app-*`, Prisma session storage):

- `shopify.app.toml` `application_url` and `[auth] redirect_urls` plus `SHOPIFY_APP_URL` env must all be
  the new URL; `shopify app deploy` (with `include_config_on_deploy = true`) pushes it to every installed
  store at once and re-targets toml-declared webhook subscriptions (relative `uri`). Rollback:
  `shopify app release --version <previous>`. Webhooks created via the API with absolute URLs keep the
  old host; check one store's `webhookSubscriptions` first.
- Token-exchange auth (`unstable_newEmbeddedAuthStrategy`) means no re-install and no re-auth as long
  as `SHOPIFY_API_KEY`/`SHOPIFY_API_SECRET` stay identical and the `Session` table is migrated.
- Webhook HMAC (`X-Shopify-Hmac-Sha256` over the raw body) is verified by `authenticate.webhook`; the
  ALB passes it; if CloudFront is in front, `/webhooks/*` must forward all headers and never cache.
- The library sets `Content-Security-Policy: frame-ancestors ...` for the embedded admin iframe; do not
  add `X-Frame-Options` or a stricter CSP at the edge.
- Checkout-time endpoints called by UI extensions or Functions are latency-sensitive and public: keep
  the web task on-demand (not Spot), cache at the app layer, and verify whether the extension bakes in
  the host.
- Rehearse with a **separate dev/staging app configuration** (`shopify app config use`) against a dev
  store; `/etc/hosts` smoke tests do not exercise the embedded flow.
- Prisma on Debian slim needs `openssl`; run `prisma generate` at build; `prisma migrate deploy` runs in
  the tools image as the migrate role (`DATABASE_MIGRATE_URL` in `secret_keys` makes the migration task
  use it as `DATABASE_URL` automatically).
- Nightly reconciliation crons (subscription polling) must not run twice: AWS schedule disabled until the
  flip, Railway cron removed at the flip.
