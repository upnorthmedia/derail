# Derail

**Railway disclosed an environment-variable breach. If you're leaving, this Claude skill plans and
generates the whole move to AWS, with Terraform.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Terraform 1.11+](https://img.shields.io/badge/Terraform-%E2%89%A5%201.11-7B42BC)
![OpenTofu 1.11+](https://img.shields.io/badge/OpenTofu-%E2%89%A5%201.11-FFDA18)
![AWS provider 6.x](https://img.shields.io/badge/AWS%20provider-6.x-FF9900)

On October 21, 2026, Railway told every customer to roll all of their environment variables. An
attacker may have accessed the systems that store them and, for some variables, obtained the decrypted
contents; Railway's first analysis suggests a subset of users is affected. Deploys were paused while
they investigated. That followed two platform incidents earlier in the year (below).

If you're done waiting for the next status-page update, point this skill at your Railway app (and your
Vercel frontend, if you have one). It produces a complete migration package: an inventory of everything
the platform knows and your code assumes, a decided architecture with an honest monthly cost next to
today's bill, validated Terraform, a Dockerfile, CI workflows, the application code changes,
data-migration scripts, and a minute-by-minute cutover runbook with rollback. It generates and
validates. Humans apply.

---

## Table of contents

- [Why people are leaving](#why-people-are-leaving)
- [Do this first: rotate everything](#do-this-first-rotate-everything)
- [What you get](#what-you-get)
- [Quick start](#quick-start)
- [Fewer keys to leak](#fewer-keys-to-leak)
- [Target architecture](#target-architecture)
- [Cost: the honest version](#cost-the-honest-version)
- [Design principles](#design-principles)
- [Supported stacks](#supported-stacks)
- [Repository layout](#repository-layout)
- [Running the evals](#running-the-evals)
- [Facts baked in](#facts-baked-in)
- [Contributing](#contributing)
- [License](#license)

---

## Why people are leaving

Railway is a great developer experience right up until it isn't. 2026 so far, from Railway's own
incident reports and disclosures:

| When | What happened |
|---|---|
| **Feb 11** | Railway's own anti-fraud system misfired and sent SIGTERM to about 3% of services on the platform, **including customer Postgres and MySQL databases**. Roughly four hours until automated recovery finished. ([incident report](https://blog.railway.com/p/incident-report-february-11-2026)) |
| **May 19 to 20** | Google Cloud suspended Railway's production account. **Every workload in every region went unreachable** for about eight hours, including ones running on Railway Metal and AWS, because routing still depended on a control plane in GCP. ([incident report](https://blog.railway.com/p/incident-report-may-19-2026-gcp-account-outage)) |
| **Oct 21** | An unauthorized party may have accessed the systems that store customer environment variables and, for some variables, obtained decrypted contents, which can include API keys and database and registry credentials. Railway says impact may be limited to a subset of users. All deployments paused. Railway's advice to everyone: roll all of it. ([disclosure](https://blog.railway.com/p/security-disclosure-wednesday-october-21st), [TechCrunch](https://techcrunch.com/2026/10/22/developer-platform-railway-urges-all-users-to-revoke-secret-keys-after-cyberattack/)) |

One incident is bad luck. Three in one year, the last a secrets breach, is a reason to own your
infrastructure.

AWS isn't magic and it isn't cheaper (see [Cost](#cost-the-honest-version)). What you get is
infrastructure you control, defined in code you can read, in an account with your own IAM, your own
audit logs, and no shared control plane between you and a stranger's bad day.

The hard part of leaving a PaaS is everything it hides: TLS, port detection, private DNS, builds from
source, secrets at build time, restart-on-crash, scale-to-zero billing, PR environments. A migration goes
wrong when those implicit behaviours are rediscovered in production at 2 a.m. This skill makes Claude
surface every one of them *before* a single resource exists, and encodes the choices that keep small
teams out of trouble: no secret values in Terraform state, same PostgreSQL major on both sides, nothing
destructive on the source platform, per-project cost visibility inside a shared account.

Built and maintained by [Up North Media](https://github.com/upnorthmedia), an Omaha web development and
AI consulting agency, while moving its own client projects off Railway and Vercel. Published under MIT so
anyone can use it.

## Do this first: rotate everything

Don't carry leaked credentials to a new home. You don't need AWS, or even a migration plan, for this
part. With the Railway CLI logged in, from your app's repo:

```bash
git clone https://github.com/upnorthmedia/derail ~/.claude/skills/derail   # same clone as Quick start
DERAIL=~/.claude/skills/derail/scripts

# 1. Before you rotate anything: list what's exposed and fingerprint the current values
$DERAIL/breach_check.sh --fingerprint migration/.secrets/railway.burned.sha256

# 2. Rotate, in the order railway-exposure.md gives you (AI provider keys first)

# 3. Prove nothing exposed is still in use
$DERAIL/breach_check.sh --verify migration/.secrets/railway.burned.sha256
```

`railway-exposure.md` lists every variable **by name** across every project you can see, grouped by
what an attacker could do with it, with what to rotate and where to look for misuse. No value is
ever printed. The fingerprints are sha256 hashes in a mode-600 file, and they matter later:
`put_secrets.sh` refuses to load any value into AWS that matches one, so a leaked key can't quietly move
house with you.

1. **Assume every value you stored in Railway is burned.** API keys, database URLs, registry
   credentials, OAuth client secrets, webhook signing secrets, session and auth secrets.
2. **Revoke and reissue them at the source** (Stripe, OpenAI, Anthropic, Twilio, your registry, your
   cloud provider), then update Railway so production keeps running while you migrate. Where a provider
   allows two live keys, deploy the new one before revoking the old; `breach_check.sh` marks each key it
   recognises with `two live`, `grace` or `hard cut`.
3. **Check the providers' logs for use you didn't make.** Railway published follow-up guidance for
   [GCP](https://blog.railway.com/p/security-disclosure-recommendation-check-for-anomalous-gcp-access)
   and [AWS](https://blog.railway.com/p/security-disclosure-recommendation-check-for-anomalous-aws-access)
   credentials specifically.
4. **Rotate your database passwords too.** If a `DATABASE_URL` leaked, the database itself is exposed
   until the password changes.
5. **Sealed variables** don't show up in any CLI output. Check each service in the dashboard.

Then run the migration and tell Claude your values were on Railway during the breach. The skill switches
to **breach mode**: it writes `migration/BREACH.md`, drops the usual "keep session secrets identical
through cutover" shortcut, and rotates session and auth secrets at the cutover minute instead, without
leaving the leaked one valid. Ordinary migrations skip all of this.

If Railway's dashboard, API or CLI is down when you start, the skill works from an exported inventory;
you don't need Railway to be up to plan your exit.

## What you get

| Deliverable | Contents |
|---|---|
| `migration/inventory/` | Railway services, variables classified by kind (values never leave your machine), domains, crons, volumes, buckets, database flavour; Vercel env vars with **Secret vs Config**, Blob stores, crons, routing rules; a static codebase scan (framework, ORM, auth, edge routes, ISR, Vercel-only imports, hard-coded hosts, local file writes) |
| `migration/PLAN.md` | Target architecture, each decision with the rejected alternative, itemised monthly cost beside the current bill, secret rotation plan, application changes, risks and open questions |
| `infra/` | Terraform: `bootstrap` (state bucket, GitHub OIDC, cost-allocation tags, account budget), shared `network`, optional shared `platform`, eleven plain-resource modules, one root per project per environment. Passes `terraform validate` and `tflint` |
| `Dockerfile`, workflows, code changes | Next.js standalone / Node / Python Dockerfiles with a separate `tools` image for migrations; GitHub Actions for plan-on-PR, apply-on-main and build → migrate → deploy; snippets for health routes, `next.config`, Payload CMS, Better Auth, webhooks, pg pools |
| `migration/DATA.md` | `pg_dump`/`pg_restore` (or logical replication) with verification, Vercel Blob / Railway bucket / volume copy, stored-URL rewrites |
| `migration/BREACH.md` | Breach mode only: every exposed variable by name, in rotation order, with what an attacker could do, where to rotate, and where to check for misuse |
| `migration/RUNBOOK.md` | T-7 to T+14: rehearsal, DNS strategy, cutover minute by minute, rollback triggers and exposure, rotation and decommissioning |

## Quick start

**Claude Code**

```bash
git clone https://github.com/upnorthmedia/derail ~/.claude/skills/derail
```

**Claude.ai / Cowork**: upload `derail.skill` from the
[latest release](https://github.com/upnorthmedia/derail/releases/latest), or build it yourself from a
`git archive` export (not a clone, which would pack `.git/` into the file):

```bash
rm -rf /tmp/derail-export && mkdir -p /tmp/derail-export/derail
git -C ~/.claude/skills/derail archive HEAD | tar -x -C /tmp/derail-export/derail
cd <skill-creator skill directory> && python3 -m scripts.package_skill /tmp/derail-export/derail /tmp/derail-export
```

Then ask, in your own words:

> "Railway got breached and I'm done. Get my app `api` and its Postgres onto AWS with Terraform.
> Repo is in `./api`. I've already rotated the keys."

> "What would it cost to run our Vercel Next.js site (DB on Railway) on AWS? We have other client
> projects in the same account and need per-project billing."

> "We have six $10/month client sites on Railway. Plan a shared AWS setup and give me the per-site cost."

Tools the skill uses when present: `railway`, `vercel`, `aws`, `terraform` or `tofu`, `tflint`,
`docker`, `pg_dump` (matching the source major), `jq`, `node`, and the Railway / Vercel / AWS MCP
servers. It works from an exported inventory when none of them are available.

## Fewer keys to leak

Every plan opens with a keyless scorecard: how many long-lived secrets your app holds on Railway today,
and how many it holds on AWS, counted from your own inventory. The difference is structural:

| On Railway | On AWS |
|---|---|
| Bucket access keys in env vars | Task IAM role, no keys |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Task IAM role, no keys |
| Database superuser password, public `DATABASE_PUBLIC_URL` | RDS-managed master secret; private-subnet database |
| `RAILWAY_TOKEN` / `VERCEL_TOKEN` in CI | GitHub OIDC, short-lived credentials |

Your third-party API keys still exist on AWS, in one Secrets Manager secret per app that only that app's
execution role can read. But the credentials that hand over your infrastructure are gone.

## Target architecture

```
Route 53 ──► (CloudFront + WAF, optional) ──► ALB (HTTPS, ACM) ──► ECS Fargate (ARM64)
                                                                  │  web task(s), strict security groups
                                                                  ├─ worker task (same image, optional)
                                                                  └─ EventBridge Scheduler → RunTask (cron)
             S3 + CloudFront OAC (media)                          RDS PostgreSQL (private subnet)
             Secrets Manager (one JSON secret per app/env, filled out-of-band)
             CloudWatch alarms → SNS · per-project Budget + Cost Anomaly Detection
             GitHub Actions via OIDC (plan / apply / deploy roles) · S3 state with native locking
```

Defaults the skill applies, each with its alternative explained in the plan:

- **ECS Fargate on Graviton** for web, worker and cron. ECS Express Mode when many small services
  share an account; OpenNext/SST only when a Next.js app is spiky or ISR-heavy and its database can be
  reached without a NAT gateway. Never App Runner (closed to new customers) or managed Amplify for Next 16.
- **Public-subnet tasks with strict security groups** at budget tiers (no NAT gateway); private
  subnets + NAT with a stable Elastic IP when a third party allow-lists your egress IP.
- **RDS PostgreSQL, same major as the source**, app-level pooling, RDS-managed master password.
  Aurora Serverless and RDS Proxy are opt-ins with their costs stated.
- **S3 + CloudFront OAC** for Vercel Blob, Railway buckets and upload volumes; EFS only when files must
  be read back by path.
- **One AWS account, many projects**: isolation by security groups, per-project IAM roles, separate
  state keys and CI roles, tags + per-project budgets. Ports 1:1 to separate accounts later.

## Cost: the honest version

Railway bills per-minute actual usage with free TLS, CDN and builds. AWS bills reserved Fargate size
plus fixed hourly fees for the load balancer and every public IPv4 address. `scripts/estimate_cost.py`
holds verified us-east-1 list prices (October 2026) and prints an itemised table next to your current bill.

| Tier | What it is | Per project / month |
|---|---|---|
| **shared** | `platform/` root: one ALB, one cluster, one RDS instance shared by N projects; 0.25 vCPU task | **~$25** (4 tenants) · ~$20 with a Spot web task · ~$13 with 8 tenants and Spot |
| **budget** | Dedicated ALB, `db.t4g.micro`, no NAT, CloudFront Free plan | ~$50 |
| **standard** | `db.t4g.small`, CloudFront Pro + WAF, Valkey if needed | ~$90 |
| **production** | Multi-AZ, private subnets + NAT, 2+ tasks, AWS Backup, Container Insights | ~$180+ |

Data transfer excluded. The shared tier is as close to Railway's pricing as AWS gets while keeping a
managed database; its blast-radius tradeoffs (one maintenance window, shared connections, shared
deletion protection) are spelled out in the plan every time.

## Design principles

1. **Secret values never appear in chat, generated files, plans or state.** Inventory scripts write
   values only to a git-ignored `migration/.secrets/` directory and print names; Terraform creates
   secret containers that are filled by `scripts/put_secrets.sh`; RDS owns its master password.
2. **The migration is a rotation event.** Vercel Secret-type and Railway sealed variables cannot be
   exported; the plan lists what is re-sourced, what stays identical through cutover (session secrets),
   and what rotates after. Nothing suggests recovering a sealed value from a running container.
3. **Nothing on AWS touches the live system before the flip.** Schedules are created disabled, DNS keeps
   pointing at the old platform until one `terraform apply` flips it, and only a maintenance switch is
   deployed to the old platform beforehand.
4. **Generate, validate, hand over.** Every root must pass `terraform fmt -check`, `validate` and `tflint`
   before the skill calls it done. It never runs `terraform apply`, flips DNS, or deletes anything.
5. **Readable by a newcomer.** Plain resources for everything you will debug at 2 a.m. (task definitions,
   target groups, IAM trust policies, RDS flags); a community module only for the VPC.

## Supported stacks

| Source | Tested |
|---|---|
| Next.js 15/16 + Payload CMS 3 on Vercel, Postgres + PgBouncer on Railway, Vercel Blob | yes (eval) |
| Next.js + Better Auth + Stripe + Twilio + PostGIS on Vercel, Postgres on Railway, DNS on Vercel | yes (eval) |
| FastAPI + Celery + Redis + Postgres + cron + upload volume, all on Railway, sealed secret, static egress IP | yes (eval) |
| Shopify embedded app (React Router + Prisma) + nightly cron + Postgres on Railway, platform hostname only | yes (eval) |
| Next.js 16 + pg-boss worker + Postgres 17 on Railway, Better Auth, OpenAI + Anthropic, Stripe, values exposed in the Oct 21 breach (breach mode) | eval written, benchmark pending |
| Generic Node (Express/Fastify/Hono/Nest), Django, Rails, Go | Dockerfiles and references cover them; no eval yet |

Railway Redis/MySQL/Mongo, buckets, volumes, TCP proxies, private networking, PR environments and
serverless sleeping are all mapped in `references/railway-inventory.md`.

## Repository layout

```
SKILL.md                     the workflow Claude follows (discover → decide → generate → data → runbook)
references/                  railway-inventory · vercel-inventory · aws-target-architecture
                             terraform-conventions · app-changes · data-migration
                             security-and-billing · cutover-runbook-template · breach-response
assets/terraform/            bootstrap/ network/ platform/ modules/ live/example-app/prod/
                             Makefile · .tflint.hcl · .pre-commit-config.yaml · .gitignore
assets/docker/               Dockerfile.nextjs · Dockerfile.node · Dockerfile.python · dockerignore
assets/app-snippets/         nextjs/ react-router/ payload/ better-auth/ webhooks/ db/
assets/github-workflows/     terraform.yml (plan/apply) · deploy.yml (build → migrate → apply)
assets/github/               dependabot.yml (weekly base-image digest + actions updates)
scripts/                     breach_check · check_prereqs · railway_inventory · vercel_inventory · scan_codebase
                             pg_migrate (+ sql/) · blob_to_s3 · railway_bucket_to_s3 · railway_volume_to_s3
                             put_secrets · estimate_cost · lib/ · tests/
evals/                       five test cases with fixture repos and inventories (fictional projects)
```

Terraform modules: `alb_https`, `ecs_service`, `rds_postgres`, `valkey`, `secrets`, `scheduled_task`,
`s3_media`, `cloudfront_app`, `budget_alerts`, `github_oidc_roles`, `migration_host`.

## Running the evals

Each folder under `evals/` is a realistic prompt plus input files and graders. With Claude Code, run
them with and without the skill:

```bash
claude plugin eval . --allow-tools Write,Edit,Bash --scaffold
```

In the first benchmark (three cases, one run each) the skill passed 44 of 45 assertions; the baseline
without it passed 34, missing on things like RDS passwords in Terraform state, a budget filter that
silently matched nothing, a root container, and documented recovery of a sealed secret.

To validate the Terraform assets locally:

```bash
cd assets/terraform && make validate ROOT=live/example-app/prod && make lint ROOT=live/example-app/prod
```

## Facts baked in

Verified against primary documentation in October 2026; they will drift. Railway `railway.json` is
deprecated (cutoff 2026-12-01) in favour of `.railway/railway.ts`; Vercel Secret-type and Railway
sealed variables cannot be exported; RDS and Aurora PostgreSQL 18 are GA; Terraform 1.17 and OpenTofu
1.13 with native S3 locking and write-only arguments; AWS provider 6.70; ECS Express Mode is GA and App
Runner is closed to new customers; CloudFront flat-rate plans exist; EventBridge Scheduler cannot call
HTTP URLs; GitHub OIDC subjects gained an immutable `org@id/repo@id` form; required reviewers on GitHub
Environments are Enterprise-only for private repositories.

If a CLI flag or price in here is wrong today, a pull request with the source link is the best fix.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Most wanted: framework snippets (Rails, Laravel, Go), an ECS
Express Mode root, an OpenNext/SST path, more eval cases, and corrections as the platforms change.
One rule above all others: no script or document may ever print a secret value.

## License

MIT. See [LICENSE](LICENSE).
