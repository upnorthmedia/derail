---
tags: [derail]
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

I want to move lumenclinic.example off Vercel + Railway and onto AWS. It's a Next.js 16 + Payload CMS 3 marketing site for an eye clinic (Node 24), media lives in Vercel Blob, and the Postgres 18 database is on Railway behind their PgBouncer. The Railway and Vercel CLIs aren't installed on this machine and there are no AWS credentials here, so I already exported the inventory into migration/inventory/ (variable names only, no values) and the repo is in ./lumen.

Plan the whole migration using Terraform. This is a cheap marketing site with a lead funnel (Typeform self-tests posting to webhooks) so keep the monthly cost down, but it has to be secure and I need to see what each project costs inside our single AWS account (we have other client projects there). Generate everything you can: inventory summary, plan with costs, Terraform, Dockerfile, CI, code changes, data migration steps and a cutover runbook. Don't apply anything.

Input files: lumen/, migration/inventory/railway/SUMMARY.md, migration/inventory/vercel/SUMMARY.md
