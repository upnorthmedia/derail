# Terraform layout for Railway/Vercel -> AWS migrations

Plain Terraform, one AWS account, any number of unrelated projects. Each project
environment is its own root directory with its own state file and its own CI
roles, so one project's `destroy` can never touch another's.

```
infra/
  bootstrap/                 # ONCE per account, by a human with admin creds
  network/                   # ONCE per account: shared VPC, subnets, (optional) NAT
  platform/                  # OPTIONAL, once per account: shared ECS cluster, ALB, RDS instance
  modules/                   # local modules; plain resources, documented
    secrets/  rds_postgres/  valkey/  alb_https/  ecs_service/  scheduled_task/
    s3_media/  cloudfront_app/  budget_alerts/  github_oidc_roles/  migration_host/
  live/
    <project>/
      prod/                  # copy of live/example-app/prod, one per environment
      staging/
  Makefile  .tflint.hcl  .pre-commit-config.yaml  .gitignore
  (workflows live in .github/workflows/terraform.yml and deploy.yml)
```

## Order of operations

1. **bootstrap** (`cd bootstrap && terraform init && terraform apply`, admin
   credentials, local state). Creates the state bucket
   `tfstate-<account>-<region>`, the GitHub OIDC provider, cost-allocation tag
   activation, the account-wide alerts topic, budget and anomaly monitor. Then
   enable its `backend.tf` and `terraform init -migrate-state` so bootstrap's
   own state moves into the bucket it created. Delete the local state files.
2. **network** (`make plan ROOT=network && make apply ROOT=network`). Shared VPC
   with 2 public + 2 private subnets, S3 gateway endpoint, NAT gateway *off* by
   default (~$33/month when on). Subnets are tagged `Tier=public|private` so
   project roots can find them without remote state.
3. **platform** (optional; `make plan ROOT=platform && make apply ROOT=platform`).
   For an account that hosts several small sites: one shared ECS cluster, one
   shared ALB (`<platform_name>-alb`, tagged `Shared=true`) and one shared RDS
   instance (`<platform_name>-db`, `db.t4g.small`). Project roots opt in per
   piece with `shared_cluster`, `shared_alb`, `shared_database`. Skip it when
   every project should stand alone.
4. **live/<project>/<env>**: copy `live/example-app/prod`, edit `backend.tf`
   (bucket + key) and `terraform.tfvars`, `make plan ROOT=live/<project>/<env>`,
   `make apply ...`. Write secrets with `scripts/put_secrets.sh`, set the GitHub
   repository variables from the outputs, push to `main`.

Repeat step 4 per project/environment. Never use Terraform workspaces to
separate projects: a workspace is a state selector, not an isolation boundary.

## What to share and what not to

Share the **fixed-cost plumbing that small sites never fill**: the ALB
(host-header rules + one SNI certificate per project), the RDS instance (one
database and one set of roles per project) and the ECS cluster (free; just
less noise). **Never share** secrets, task/execution roles, log groups, S3
buckets, ECR repositories or Terraform state: those are the isolation
boundary that lets one project be destroyed, audited or handed to a client
without touching another. The trade-off is blast radius (one maintenance
window, one failover, one `max_connections` for every tenant on the shared
instance); `platform/README.md` spells it out and says when to move a
project back onto its own instance.

Per-project marginal cost on the shared platform (us-east-1, Oct 2026):
share of the shared ALB (~$25/N) + share of the shared instance (~$26/N) +
one 0.25 vCPU / 0.5 GiB task ($7.21 on-demand, ~$2-3 on Fargate Spot) + its
public IPv4 ($3.65) + its app secret ($0.40). With four tenants that is
~$24/month on-demand or ~$19 on Spot, against ~$55-65 for a dedicated stack.

## Conventions (every root and module)

- `required_version = ">= 1.11, < 2.0"`, provider `hashicorp/aws ~> 6.70` in
  roots (`>= 6.28` in modules). Commit `.terraform.lock.hcl`; CI runs
  `init -lockfile=readonly` so provider upgrades are explicit.
- Roots set `default_tags` = `{ Project, Environment, ManagedBy, Repository }`;
  modules add only `Name`. Cost per project = Cost Explorer grouped by `Project`
  (the shared pool is its own `Project = platform` line; split it with a Cost
  Category or simple division, see `platform/README.md`).
- Names: `local.name = "<project>-<environment>"`, resources `<name>-<component>`.
- No secret values in Terraform: RDS manages its master password, app secrets
  are Secrets Manager containers whose values are written by
  `scripts/put_secrets.sh`, ECS reads them with `valueFrom`.
- Guardrails: `prevent_destroy` on the database and the state bucket, RDS
  `deletion_protection`, ECS deployment circuit breaker with rollback,
  validated variables with cost comments wherever a choice costs money.
- State: S3 backend with `use_lockfile = true` (native S3 locking, no DynamoDB),
  key `<project>/<env>/terraform.tfstate`.

## Daily commands

```sh
make plan  ROOT=live/acme-app/prod     # init + plan -> tfplan
make apply ROOT=live/acme-app/prod     # apply that exact plan
make lint                              # tflint (+ trivy if installed) on the whole tree
make fmt                               # terraform fmt -recursive
make cost  ROOT=live/acme-app/prod     # infracost breakdown (free API key needed)
make destroy ROOT=live/acme-app/staging
```

`pre-commit install` runs fmt/validate/tflint/trivy/terraform-docs on commit.

## CI

- `terraform.yml`: on pull requests, fmt-check, validate, tflint, trivy and a
  `plan` posted as a PR comment using the `-github-plan` role (read-only +
  state). On push to `main`, `apply` using the `-github-apply` role behind a
  GitHub Environment and a concurrency group.
- `deploy.yml`: on push to `main`, build the image for `linux/arm64`, push to
  ECR tagged with the git SHA (`-github-deploy` role), then
  `terraform apply -var image_tag=<sha>` (`-github-apply` role), then runs the
  `<project>-<env>-tools` task definition (`-github-deploy` role, output
  `migration_run_task`) for database migrations before the web service rolls.

GitHub Environments with required reviewers are Enterprise-only for private
repos; for everyone else the gate is a protected `main` branch plus PR review.

## OpenTofu

Everything here runs unchanged on **OpenTofu >= 1.11**: `make plan TF=tofu ...`,
or set `TF=tofu` in your shell. The only differences that matter: OpenTofu
allows variables in `backend` blocks and a dynamic `prevent_destroy`; this code
deliberately uses neither so it stays portable in both directions.

## Where things are documented

Every module has a README with an inputs/outputs table, a cost note and a
gotchas list. Each root README has the apply/rollback/decommission runbook.
Start with `live/example-app/prod/README.md`.
