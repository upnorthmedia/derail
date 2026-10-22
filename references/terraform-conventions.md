# Terraform conventions used by the generated code

Verified 2026-10-22: Terraform 1.17.0 current (1.11 is the floor for write-only args and native S3
locking), OpenTofu 1.13.2 (1.11 has parity for both), AWS provider 6.70 (v6 since June 2025).

## Contents
1. Layout and order of operations
2. Backend, state, bootstrap chicken-and-egg
3. Secrets rules (nothing sensitive in state)
4. Image tag ownership (Terraform-owned by default)
5. Guardrails baked into the modules
6. CI (plan on PR, apply on main) and the private-repo approval caveat
7. OpenTofu compatibility
8. Newcomer mistakes the code prevents, and ones it cannot

## 1. Layout

```
infra/
  bootstrap/            once per account, human admin creds: state bucket, GitHub OIDC provider,
                        cost-allocation tag activation, account budget + anomaly monitor, alerts topic
  network/              once per account: shared VPC (2 AZ, public + private subnets, no NAT by default)
  platform/             optional, once per account: shared ECS cluster, shared ALB (+ default cert on a
                        platform hostname), shared RDS instance; projects opt in with shared_cluster /
                        shared_alb / shared_database and attach their own cert (SNI) and listener rule
  modules/              plain-resource local modules (alb_https, ecs_service, rds_postgres, valkey, secrets,
                        scheduled_task, s3_media, cloudfront_app, budget_alerts, github_oidc_roles, migration_host)
  live/<project>/<env>/ one root per project per environment = one state file, one set of CI roles
  Makefile  .tflint.hcl  .pre-commit-config.yaml  .gitignore
.github/workflows/terraform.yml  deploy.yml
```

Order: `bootstrap` (apply, then migrate its own state into the bucket) -> `network` -> `platform`
(shared tier only) -> `live/<project>/<env>`. Shared resources are tagged `Project=platform`; what is
never shared: secrets, task/execution roles, log groups, buckets, state keys, CI roles.
Modules for the VPC (terraform-aws-modules/vpc ~> 6.7) only; everything a human will debug at 2 a.m.
(task definition, target group, IAM trust policies, RDS flags) is a plain resource in the open.

Workspaces are not used to separate projects or clients (HashiCorp's docs: not an isolation
mechanism). Terragrunt is a later upgrade when copy-pasted `backend.tf` files become painful.

Naming: `local.name = "${var.project}-${var.environment}"`; resources `${local.name}-<component>`;
IAM roles under path `/projects/<project>/` or prefixed `${local.name}-`. Tags on every resource via
`provider "aws" { default_tags }`: `Project`, `Environment`, `ManagedBy=terraform`, `Repository`.
ECS tasks get them only with `propagate_tags = "SERVICE"` + `enable_ecs_managed_tags` (the module sets both).

## 2. Backend and state

```hcl
terraform {
  required_version = ">= 1.11, < 2.0"
  backend "s3" {
    bucket       = "tfstate-<account-id>-<region>"   # created by bootstrap; hard-coded on purpose
    key          = "<project>/<env>/terraform.tfstate"
    region       = "<region>"
    use_lockfile = true      # native S3 locking; DynamoDB table deprecated since 1.11, OpenTofu supports both
    encrypt      = true
  }
}
```

Backend blocks cannot take variables in Terraform (they can in OpenTofu 1.8+), and Terraform 1.15+
validates the backend block, so the generated roots hard-code bucket/key/region (they are not secrets).
Bootstrap flow: apply `bootstrap/` with local state -> copy `backend.tf.example` to `backend.tf` ->
`terraform init -migrate-state` -> delete local `terraform.tfstate*`. The bucket has versioning,
SSE, public access block, TLS-only policy, 90-day noncurrent expiry and `prevent_destroy`.
CI roles may read/write only their own `<project>/<env>/*` prefix (including `.tflock`), never `bootstrap/*`.

## 3. Secrets

- RDS: `manage_master_user_password = true` (RDS-owned Secrets Manager secret, auto-rotated, never in
  state). The app connects as a separate least-privilege role whose URL lives in the app secret.
- App secrets: Terraform creates one JSON secret **container** per app/env (`<project>-<env>/app`);
  values are written by `scripts/put_secrets.sh` from a local, git-ignored `.env` file. Terraform never
  reads or writes the value, so nothing sensitive is in plan output or state. ECS injects each key with
  `valueFrom = "<arn>:<KEY>::"` at task start (rotate = put new value + force new deployment).
- If a project insists on Terraform-managed values, use write-only arguments
  (`aws_secretsmanager_secret_version.secret_string_wo` + `_wo_version`, `aws_db_instance.password_wo`),
  available in Terraform 1.11+/OpenTofu 1.11+, with an `ephemeral = true` variable. Never
  `secret_string`, `password`, or `data "aws_secretsmanager_secret_version"` (all land in state).
- Outputs expose ARNs and endpoints, never values. Agents and CI must not run `GetSecretValue` and echo it.

## 4. Image tag ownership

Default: **Terraform owns `image_tag`**. `deploy.yml` builds and pushes `<sha>` and runs
`terraform apply -var image_tag=<sha>`; `terraform.yml` reads the current tag from `terraform output`
so an infra-only apply never rolls the app back. One source of truth; the plan output is the deploy log.
Alternative for teams with an existing pipeline: CI registers task definitions itself and the service
gets `lifecycle { ignore_changes = [task_definition] }` (two writers; env changes need care). Pick one.

First apply happens before any image exists: `image_tag = "bootstrap"` creates the ECR repo and a
service whose first deployment fails to pull (expected). Build/push, `put_secrets.sh`, run the
migration task, then apply with the real tag. Set `desired_count = 0` on the first apply if the
failed-deployment noise bothers you.

Migrations: the root registers a `tools` task definition (`<name>-tools`, same roles/secrets/env as
the web task, image `<tag><tools_image_tag_suffix>`, command `migration_command`). `deploy.yml` copies
that definition, points it at the freshly pushed `<sha>-tools` image, runs it once and waits for exit 0
**before** `terraform apply` rolls the service, which is the order Railway's `preDeployCommand` gave
you. The deploy role may `RunTask` only that family in the project cluster.

DNS cutover: `traffic_target = "old"` keeps Terraform from creating apex/www records that point at AWS
(and, when the zone was created by Terraform, serves `old_platform_records` instead), so a zone can be
delegated to Route 53 a week early; `traffic_target = "aws"` in one apply is the flip, and `crons_enabled`
flips the schedules in the same apply. `github_environment` must equal the apply job's `environment:`.

## 5. Guardrails in the modules

`prevent_destroy` + `deletion_protection` + `skip_final_snapshot = false` on RDS; versioned, encrypted,
TLS-only state bucket with `prevent_destroy`; ECS circuit breaker with rollback and
`minimumHealthyPercent = 100`; ALB health check path validated as a variable, matcher 200-399, grace
period 60 s; execution role scoped to the exact secret ARNs (prevents the classic
`ResourceInitializationError: unable to pull secrets`); task role separate from execution role;
`-lockfile=readonly` in CI so provider upgrades are explicit; `~>` pins on providers and modules;
validations on project slug, environment, ports, cpu/memory pairs, retention days, cron syntax.
Decommissioning a project is a two-step: set `deletion_protection = false`, apply, then destroy
(RDS takes a final snapshot named `<name>-db-final`; rename it in the module if one already exists).

## 6. CI

`terraform.yml`: on PR -> fmt, validate, tflint, trivy config, `plan` posted as a comment (plan role,
read-only + state prefix). On push to `main` -> plan + apply (apply role) under a `concurrency` group and
the `prod` GitHub Environment. **Caveat:** required reviewers and wait timers on GitHub Environments are
only available for public repos on Free/Pro/Team (private repos need Enterprise). Fallback: protected
`main` with PR review, apply only on push to main, or make apply `workflow_dispatch` so a human presses
the button. `deploy.yml`: buildx `linux/arm64` -> ECR -> optional migration RunTask -> apply with the tag.
Auth is GitHub OIDC only (no long-lived keys); trust policies include both subject forms
(`repo:org/repo:...` and `repo:org@<id>/repo@<id>:...`) because repos created after 2026-07-15 emit the
latter. Thumbprints are no longer required for the GitHub provider.

Static checks: `terraform fmt -check`, `terraform validate`, tflint (terraform recommended preset +
aws ruleset), `trivy config` (tfsec is frozen), optional checkov. Infracost CLI is free (1,000 runs/mo)
for `make cost`.

## 7. OpenTofu

The generated code runs unchanged on OpenTofu >= 1.11 (`TF=tofu make plan`). Shared: native S3
lockfile, ephemeral/write-only, `moved`/`removed`/`import`/`check`. Not used: Stacks, actions,
list/query (Terraform/HCP-only). OpenTofu extras not relied on: state encryption, dynamic
`prevent_destroy`, variables in backend blocks. Keep `prevent_destroy` literal for portability.

## 8. Mistakes

Prevented: state in git, unversioned state bucket, admin keys in CI, hard-coded account IDs, inactive
cost-allocation tags, unpinned providers, DB destroyed by a rename (use `moved {}`), execution role
without secret access, missing egress for image pulls (public IP or NAT is explicit), health-check
path mismatch, destroy failing on final snapshot, plaintext secrets in state, console tag drift,
applying project B with project A's role, workspaces as isolation.

Not preventable by code (say them in the runbook): forgetting to confirm the SNS email subscription;
cost-allocation tags taking 24 h to appear; running `terraform apply` from a laptop with broad creds
after CI exists; editing the task definition in the console (Terraform reverts it next apply).
