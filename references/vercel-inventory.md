# Vercel inventory: what to discover, how to export it, where it goes on AWS

Facts verified against vercel.com/docs and nextjs.org/docs on 2026-10-22.

## Contents
1. Headline facts
2. Discovery commands
3. Primitive mapping table
4. Code-level Vercel dependencies to grep for
5. Next.js version notes that affect the Dockerfile

## 1. Headline facts

- Environment variables are typed **Config** (readable) or **Secret** (write-only). Production and
  Preview default to Secret. `vercel env pull` writes a **placeholder** for Secret values: there is no
  API that returns them. Every Secret must be re-sourced from its provider (Stripe, Twilio, Resend,
  Google) or regenerated (`PAYLOAD_SECRET`, `BETTER_AUTH_SECRET`, `REVALIDATE_SECRET`, `CRON_SECRET`).
  Exception: keep `PAYLOAD_SECRET` / session secrets **identical** through cutover if you can recover
  them (otherwise all users are logged out and Payload-encrypted fields become unreadable); rotate later.
- Vercel KV and Vercel Postgres no longer exist as first-party products; data lives at Marketplace
  providers (Neon, Upstash, Supabase). Export from the provider, not from Vercel. Edge Config is now
  **Global Config** (export with `getAll()` to JSON; AWS: SSM Parameter Store / AppConfig).
- Vercel Blob has no export feature; copy with `scripts/blob_to_s3.ts` (list -> head -> stream to S3).
  `list()` does not return `contentType`; the script calls `head()` per blob so S3 objects are not
  `application/octet-stream`. Rate limits: Hobby 20 ops/s, Pro 120 ops/s.
- Cron Jobs (`vercel.json` `crons`) are HTTP GETs to the production URL with `Authorization: Bearer
  $CRON_SECRET` by convention. EventBridge **Scheduler cannot call HTTP endpoints**; use an EventBridge
  rule -> API destination, or (simpler, what the skill generates) Scheduler -> ECS RunTask running a
  script with the same logic. Keep the bearer check if the route stays.
- ISR, the Data Cache and `revalidateTag()` purging the CDN are Vercel platform features. Self-hosted,
  each task has its own cache and `revalidateTag()` never purges CloudFront. See
  `assets/app-snippets/nextjs/cache-handler.md`.
- `vercel.json` `rewrites/redirects/headers/cleanUrls/trailingSlash/functions/regions` are honored
  **nowhere else**; port them to `next.config` (or CloudFront Functions for pure path redirects).
- App Runner is closed to new customers (2026); AWS's stated replacement is ECS Express Mode.

## 2. Discovery commands

`scripts/vercel_inventory.sh --project <name> --team <slug> --out migration/inventory/vercel` runs:

```bash
vercel link --yes --project <name> --scope <team>
vercel project ls; vercel project inspect <name>          # framework, node version
vercel env ls production                                   # names + Config/Secret
vercel env pull migration/.secrets/vercel.production.env --environment=production --yes
vercel env pull migration/.secrets/vercel.preview.env --environment=preview --yes
vercel domains ls; vercel dns ls <domain>
vercel blob list --limit 1000                              # needs BLOB_READ_WRITE_TOKEN in env
```

If the Vercel MCP server is connected: `list_projects`, `get_project` (framework, nodeVersion, domains,
protection), `filter_project_envs` (names/types; values stay encrypted), `list_project_domains`,
`get_firewall_config` (export WAF rules), `list_project_routes`, `get_records` (DNS).

## 3. Primitive mapping

| Vercel | Export | AWS equivalent | Gotchas |
|---|---|---|---|
| Project (Next.js, Node 24) | `project inspect` | ECS Fargate service (default) or OpenNext (see aws-target-architecture.md) | Match the Node major in the Dockerfile. |
| Env vars Config | `env pull` | `plain_env` (task definition) or build args for `NEXT_PUBLIC_*` | `NEXT_PUBLIC_*` are inlined at build: Docker build args. |
| Env vars Secret | not exportable | `secret_keys` + `scripts/put_secrets.sh` with re-sourced values | Plan the rotation list explicitly. |
| System vars (`VERCEL_URL`, `VERCEL_ENV`, `VERCEL_GIT_COMMIT_SHA`, `VERCEL_PROJECT_PRODUCTION_URL`) | grep code | `APP_URL`, `NODE_ENV`, `GIT_SHA` set by you | Code reading `VERCEL_URL` for absolute URLs breaks silently. |
| Vercel Blob | `blob list` + SDK | S3 private bucket + CloudFront OAC (`enable_media_bucket`) | Rewrite stored `*.blob.vercel-storage.com` URLs in DB rows and rich text. |
| Marketplace Postgres (Neon etc.) | provider `pg_dump` | RDS PostgreSQL | Same procedure as Railway Postgres. |
| Upstash KV | provider | ElastiCache Serverless Valkey, or keep Upstash | Usually cache/session data; often not worth migrating. |
| Global Config | `getAll()` | SSM Parameter Store / AppConfig | No sub-ms replicated read path on AWS. |
| Cron jobs | `vercel.json` | `cron_jobs` -> EventBridge Scheduler -> RunTask | Hobby crons had ±59 min jitter; Scheduler is exact. |
| Routing Middleware / `proxy.ts` | code | Runs inside the Next server on Fargate | `export const runtime = 'edge'` routes must become Node. |
| ISR / Data Cache | code (`revalidate`, `revalidateTag`) | Shared cache handler on Valkey, or `force-dynamic` + CloudFront `s-maxage`, or OpenNext | Add CloudFront invalidation if instant updates matter. |
| Image Optimization | automatic | `next/image` with sharp in the container (works out of the box) | Add media host to `images.remotePatterns`. |
| `vercel.json` rewrites/redirects/headers | `vercel.json` | `next.config` equivalents; CloudFront Functions for path redirects | Export before deleting the project. |
| Preview deployments | automatic | None cheap; one `staging` root | Say so up front. |
| Domains / DNS on Vercel | `domains ls`, `dns ls` | Route 53 hosted zone + alias records | Move NS a week early or keep Vercel DNS and only change records at cutover. |
| Deployment Protection / Trusted IPs | `get_project` | CloudFront + WAF IP allow-list; basic auth via CloudFront Functions on staging | |
| Vercel Firewall / WAF rules | `get_firewall_config` | AWS WAF on CloudFront (`enable_waf`): Common rules, IP reputation, Known bad inputs, rate limit | CRS body rules false-positive on CMS admin saves; the module counts them instead of blocking. |
| Web Analytics / Speed Insights | dashboard only | CloudWatch RUM, PostHog, Umami, Plausible | Remove `@vercel/analytics` components. |
| Function limits (4.5 MB body, 300-800 s) | n/a | ALB: no body limit; CloudFront origin timeout max 60 s | Long routes must bypass CloudFront or stream early bytes. |

## 4. Code-level Vercel dependencies to grep for

`@vercel/blob`, `@vercel/kv`, `@vercel/postgres`, `@vercel/edge-config`, `@vercel/functions`
(`geolocation()`, `ipAddress()`, `waitUntil()` -> use `after()` from `next/server`), `@vercel/analytics`,
`@vercel/speed-insights`, `@vercel/og` (fine on Node), `x-vercel-*` headers (`x-vercel-ip-country` ->
`CloudFront-Viewer-Country`), `VERCEL_*` env, `export const runtime = 'edge'`, `export const
preferredRegion`, `unstable_cache`, `'use cache: remote'`, `revalidateTag(tag)` single-arg (deprecated in
16), `vercel.json`, `.vercel/`. `scripts/scan_codebase.py` reports all of these.

## 5. Next.js version notes (Oct 2026)

- Next.js 16.4.x current; 16.4.1 / 15.5.28 were security releases (two critical RCEs, Oct 14 2026).
  Pin `next` to the newest patch and `sharp >= 0.35.5` (image optimizer RCE on glibc).
- Next 16: `middleware.ts` -> `proxy.ts` (Node runtime), `images.minimumCacheTTL` default 4 h,
  `images.qualities` default `[75]`, `serverRuntimeConfig`/`publicRuntimeConfig` removed, Turbopack default.
- Self-hosting docs now require for multi-instance deploys: `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` identical
  across tasks of a build, `deploymentId` for skew protection, and a shared `cacheHandler` for ISR.
- Payload CMS 3.9x: swap `@payloadcms/db-vercel-postgres` -> `@payloadcms/db-postgres`,
  `@payloadcms/storage-vercel-blob` -> `@payloadcms/storage-s3`; run `payload migrate` as a one-off task.
- Better Auth 1.7: set `BETTER_AUTH_URL` explicitly; CLI is `npx auth@latest generate|migrate|check`.
