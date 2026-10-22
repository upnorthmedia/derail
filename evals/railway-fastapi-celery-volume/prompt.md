---
tags: [railway-to-aws]
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

our backend is entirely on railway and we need to be on AWS in eu-central-1 by end of quarter (customer contract). it's a python 3.12 fastapi api (2 replicas), a celery worker, redis, postgres 16 with pgvector, a nightly cron service, and the api writes uploaded PDFs to a railway volume at /data that the worker then OCRs. there's also a sealed BANK_API_KEY we can't read out of railway, and the bank allow-lists railway's static outbound IPs. we can take ~2 hours downtime on a sunday. railway CLI isn't on this machine; inventory export is in migration/inventory/railway/SUMMARY.md and the repo is ./api.

give us terraform + the plan + the data migration + a runbook. we have one AWS account for everything so keep the projects separated for billing. don't apply anything.

Input files: api/, migration/inventory/railway/SUMMARY.md
