# Vercel inventory: project `pawbook` (team acme-studio)
Exported 2026-10-22. Framework: nextjs. Node: 24.x. Production READY (2026-08-16).
Domains: pawbook.example (apex), www.pawbook.example, pawbook-acme-studio.vercel.app. DNS for pawbook.example is on **Vercel DNS** (ns1/ns2.vercel-dns.com).
Deployment protection: SSO on all except custom domains. Firewall: 1 custom rule (rate limit /api/auth/* 60 req/min).

## Environment variables (production + preview)
| Name | Type |
|---|---|
| DATABASE_URL | Secret (sensitive) |
| BETTER_AUTH_SECRET | Secret (legacy encrypted) |
| BETTER_AUTH_URL | Config |
| GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET | Secret |
| GOOGLE_MAPS_API_KEY | Secret (sensitive) |
| STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET | Secret (sensitive) |
| NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY | Secret (sensitive; note: it is a publishable key) |
| TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_MESSAGING_SERVICE_SID | Secret (sensitive) |
| SMS_ENABLED | Secret (sensitive) |
| RESEND_API_KEY, RESEND_FROM_EMAIL | Secret (sensitive) |
| CRON_SECRET | Secret |

vercel.json: 2 crons (/api/cron/reminders daily 14:00 UTC, /api/cron/cleanup weekly), functions maxDuration 30. No Blob store. Traffic: ~300k requests/month, peaks Saturday mornings; ~1,200 paying customers; Stripe + Twilio webhooks in use.
