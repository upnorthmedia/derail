# Vercel inventory: project `lumen` (team acme-studio)
Exported 2026-10-22. Framework: nextjs. Node: 24.x. Latest production deployment READY (2026-10-07).
Domains: lumenclinic.example (apex), www.lumenclinic.example, lumen-acme-studio.vercel.app. DNS for lumenclinic.example is hosted at Cloudflare (CNAME flattening to Vercel), NOT on Vercel DNS.
Deployment protection: SSO on all except custom domains. Vercel Firewall: default (no custom rules). Analytics + Speed Insights enabled.

## Environment variables (production unless noted)
| Name | Type | Note |
|---|---|---|
| NEXT_PUBLIC_SERVER_URL | Config | https://lumenclinic.example |
| DATABASE_URL | Secret (legacy encrypted) | points at Railway DATABASE_PUBLIC_URL (PgBouncer) |
| DATABASE_UNPOOLED_URL | Secret | Railway DATABASE_PUBLIC_UNPOOLED_URL (used by payload migrate) |
| PAYLOAD_SECRET | Secret | |
| REVALIDATE_SECRET | Secret | also a different value in preview |
| LUMEN_BLOB_READ_WRITE_TOKEN | Secret | Blob store store_XXXXXXXXXXXXXXXX (public store, ~1,900 objects, 3.4 GB, prefix media/) |
| LUMEN_BLOB_STORE_ID | Config | |
| LUMEN_BLOB_WEBHOOK_PUBLIC_KEY | Config | |
| TYPEFORM_SELF_TEST_SECRET | Secret | |
| SELF_TEST_LASIK_WEBHOOK_URL / SELF_TEST_CATARACT_WEBHOOK_URL / SELF_TEST_RLE_WEBHOOK_URL | Secret (sensitive) | Zapier/Make webhook URLs |
| CONTACT_FORM_WEBHOOK_URL | Secret (sensitive) | |
| STAGING_PASSWORD | Secret | preview only |

`vercel env pull` wrote placeholders for all Secret-type values. vercel.json: 1 header rule, 1 redirect, no crons. Traffic: ~40k requests/month, ~25 GB egress/month.
