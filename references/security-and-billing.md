# Security and billing in a single shared AWS account

How several unrelated projects live safely in one account with clear per-project costs. Verified
2026-10-22. Implemented by `bootstrap/`, `modules/github_oidc_roles`, `modules/budget_alerts`, and the
tagging in every root.

## Contents
1. Identity: humans and CI
2. Per-project isolation inside one account
3. Secret handling rules (for humans, CI, and the agent)
4. Billing clarity: tags, budgets, anomaly detection, cost categories
5. Baseline alarms and backups
6. When to graduate to AWS Organizations

## 1. Identity

- **Humans**: IAM Identity Center (`aws login` / SSO) with MFA; the only human-run roots are
  `bootstrap/` and `network/`. Avoid long-lived access keys entirely.
- **CI**: GitHub Actions OIDC. `bootstrap/` creates the provider (`token.actions.githubusercontent.com`,
  audience `sts.amazonaws.com`; thumbprints are no longer used by AWS for GitHub). Each project root
  creates three roles under `/projects/<project>/`:

| Role | Trusted subjects | Permissions |
|---|---|---|
| `<name>-github-plan` | `repo:org/repo:pull_request`, `repo:org/repo:ref:refs/heads/*` | ReadOnlyAccess + state read/write-lock on `<project>/<env>/*` |
| `<name>-github-apply` | `repo:org/repo:ref:refs/heads/main` and/or `repo:org/repo:environment:prod` | PowerUserAccess + IAM on `/projects/<project>/` and `<name>-*` roles/policies (permission boundary available), state RW on its prefix, explicit Deny on other prefixes and `bootstrap/*` |
| `<name>-github-deploy` | `ref:refs/heads/main` | ECR push on the project repos, `ecs:UpdateService`/`RegisterTaskDefinition` on the project cluster, `iam:PassRole` on the two task roles |

  Both subject forms are included (`repo:org/repo:...` and `repo:org@<ownerId>/repo@<repoId>:...`)
  because repositories created after 2026-07-15 emit the immutable form; a trust policy with only the
  old form fails silently for them (`github_repository_ids` input). Never trust `repo:org/*` for apply.
- PowerUserAccess is a pragmatic ceiling for solo developers and small agencies; the README says so and
  shows how to tighten to ABAC (`aws:ResourceTag/Project`) once the stack is stable. Note that not
  every action supports resource tags (`ecs:RegisterTaskDefinition`, many `Describe*`), so ABAC is paired
  with name-prefix ARNs.
- GitHub Environments with required reviewers are Enterprise-only for private repos; the fallback
  approval gate is protected `main` + PR review, or `workflow_dispatch` apply.

## 2. Per-project isolation

- Separate Terraform state key and CI roles per project/environment; the state policy denies object
  access outside the project's prefix and all access to `bootstrap/*`.
- Security groups: the task SG allows inbound only from the ALB SG on the container port; the RDS SG
  only from the project's task SGs on 5432. No SG references across projects.
- IAM: task role (what the app can do: S3 media bucket, SES) is separate from the execution role
  (pull image, write logs, read the project's secrets only). ECS Exec is opt-in and audited via SSM.
- Secrets Manager: one secret per project/env; execution role may read only that ARN; optional
  per-project KMS CMK ($1/mo) for cryptographic separation (standard tier and above).
- Tags `Project`/`Environment`/`ManagedBy`/`Repository` on everything via `default_tags`, plus
  `propagate_tags = "SERVICE"` so Fargate task usage is attributable.
- Network is shared (one VPC) by design; isolation is SG + IAM + tags, which is the same model the
  per-account layout would use, so moving a project to its own account later is a state move, not a rewrite.

## 3. Secret handling rules

1. Variable **values** never appear in chat, plans, logs, commit messages, or Terraform state. The
   inventory scripts write values only to `migration/.secrets/*.env` (umask 077, git-ignored) and print
   names and classifications. The agent never `cat`s those files, never runs `GetSecretValue` and echoes it.
2. The migration is a **rotation event**: Vercel Secret-type variables cannot be exported, Railway
   sealed variables cannot be exported, and exported values sat on a laptop. Sealed/Secret values are
   re-issued by their provider (the bank, Stripe, Twilio); do not propose reading them out of a running
   container's process environment, and if someone does that anyway the value must be rotated immediately. Plan: re-source API keys
   from providers; generate new `CRON_SECRET`/`REVALIDATE_SECRET`; keep `PAYLOAD_SECRET`,
   `AUTH_SECRET`/`BETTER_AUTH_SECRET` identical through cutover (sessions/encrypted fields) and rotate
   them with a planned re-login a week later; dual-register webhooks so each platform has its own
   signing secret; rotate the RDS app-user password and delete Railway's TCP proxy after cutover.
3. `scripts/put_secrets.sh` writes the JSON secret from the `.env` file via a temp file, prints key
   names and the new version id only, and refuses `RAILWAY_*`/`VERCEL_*` keys and `NEXT_PUBLIC_*`
   (build-time, not secret) unless overridden.
4. ECS reads secrets at task start only; after rotation run a forced new deployment.
5. Terraform: `manage_master_user_password`, secret containers without versions, write-only arguments
   if values must be managed; `sensitive = true` on anything that could leak into output; never
   `terraform output` or `state pull` in CI logs.
6. Shred local dump files and `.secrets/` after the post-cutover rotation (`rm -P` / secure delete),
   including CI artifact storage.

## 4. Billing clarity

- **Cost allocation tags must be activated** (Billing -> Cost allocation tags, or
  `aws_ce_cost_allocation_tag` in bootstrap). A new key appears up to 24 h after first use and takes
  up to 24 h more to activate; costs before activation are not attributed. Bootstrap exposes
  `activate_cost_allocation_tags` (apply once resources exist, wait a day, set true, apply again).
  Activate `aws:createdBy` too (free) to catch resources created outside Terraform.
- **Per-project Budget** (free for notification-only budgets, unlimited): monthly cost filtered on
  `user:Project$<slug>`, alerts at 80% actual and 100% forecast to the project's SNS topic. Account-wide
  budget in bootstrap. Action-enabled budgets cost $0.10/day after two; not used.
- **Cost Anomaly Detection** (free): one AWS-services monitor account-wide (bootstrap) and one tag
  monitor per project with an absolute threshold (default $10); needs ~10 days of history and lags 24 h.
- **Cost Categories** (free): map tag `Project` -> value, NAT/data-transfer usage types -> `shared-network`,
  Support/Tax -> `account-overhead`, default `unallocated`. Expect 5-15% of a small account to land in
  "No Project" (inter-AZ transfer, Logs Insights queries, Support, tax).
- **Cost Explorer** grouped by tag `Project` is the client invoice view; CUR 2.0 export to S3 is free and
  worth enabling on day one. Billing Views can scope Cost Explorer to a tag filter for a client.
- Free Tier changed 2025-07-15: new accounts get up to $200 credits on a 6-month free plan that blocks
  CloudFront flat-rate plans and some services; use the **paid account plan** for a real migration.

## 5. Baseline alarms and backups

Twelve alarms per project (10 free, then $0.10 each): ALB target 5xx, ALB 5xx, unhealthy hosts, p95
latency (optional), ECS CPU and memory > 85%, RDS CPU > 80%, free storage < 2 GB, connections > ~70%
of max, credit balance < 20 (t-class), freeable memory < 100 MB, budget 80/100%. All to one SNS topic
with an email subscription (confirm the email once). `treat_missing_data = notBreaching` on counts.
RDS automated backups (7 days dev, 14-35 prod) + PITR; AWS Backup plan at production tier; ECR image
scanning on push and a lifecycle policy; S3 media versioning. Uptime from outside: Route 53 health check.

## 6. When to graduate to Organizations

A project has its own compliance scope (SOC 2, HIPAA), needs its own service quotas (ALB/EIP/VPC
limits are per account), an external collaborator needs console access, billing must be invoiced from
a separate AWS account, or a blast-radius incident would be unacceptable. Organizations is free;
Control Tower adds ~$5-15/mo per account. The generated layout (per-project state, roles, tags, no
hard-coded account IDs) moves to a member account with a backend change and a state migration.
