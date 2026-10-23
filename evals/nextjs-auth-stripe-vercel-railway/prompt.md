---
tags: [derail]
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

pawbook.example is a Next.js 16 app (Node 24) on Vercel with Better Auth (Google login), Stripe payments, Twilio SMS reminders, Resend email and Google Maps; its Postgres 18 is on Railway and uses PostGIS. We have paying customers so this needs to be solid, not the absolute cheapest. The DNS is on Vercel DNS which worries me for the switch. We can take maybe 15 minutes of write downtime on a weeknight. I've put the exported inventories under migration/inventory/ (names only) and the repo is in ./pawbook. No Railway/Vercel/AWS access from this box.

Give me the migration plan to AWS with Terraform (we already run other client projects in the same AWS account and need per-project cost visibility), the infra code, the app changes, the database and cutover procedure. Also tell me honestly what it's going to cost vs today. Don't run anything against AWS.

Input files: pawbook/, migration/inventory/railway/SUMMARY.md, migration/inventory/vercel/SUMMARY.md
