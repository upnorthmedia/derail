---
tags: [derail]
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

Next one: our Shopify app "Geo Gate" runs entirely on Railway (project <railway-project-id>): an `app` service built by Railpack from acme-studio/geo-gate-shopify, a `cron` service that runs `npm run poll:subscriptions` nightly, and Postgres 18. It's the Shopify React Router app template with Prisma session storage. It only has the Railway-provided domain right now and that hostname is what's registered with Shopify as the app URL and OAuth redirects. ~40 merchants installed. I pulled the Railway inventory (names only) into migration/inventory/railway/SUMMARY.md and a copy of the repo is in ./geo-gate-shopify. No AWS/Railway/GitHub access from here.

We're going to move Lumen and Pawbook too, so this should go in the same AWS account using the shared setup if that makes sense for a $7/month app. Plan it with Terraform, give me the code, the Shopify-specific gotchas (app URL change, webhooks, embedded iframe), the DB migration and the cutover. Don't apply anything.

Input files: geo-gate-shopify/, migration/inventory/railway/SUMMARY.md
