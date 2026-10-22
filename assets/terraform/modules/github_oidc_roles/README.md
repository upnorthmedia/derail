# modules/github_oidc_roles

Three IAM roles that GitHub Actions can assume for one project, using
OpenID Connect instead of access keys. GitHub proves "this job is running
for repo X on branch Y", AWS hands out credentials that last an hour, and
there is nothing to leak or rotate.

| Role | Who may assume it | What it can do |
|---|---|---|
| `<name>-github-plan` | pull requests and pushes to **any** branch of the repo | `ReadOnlyAccess` + read this root's state + take/release the state lock. Cannot change anything. |
| `<name>-github-apply` | pushes to `apply_branch` (default `main`), and jobs in `github_environment` if set | `PowerUserAccess` + IAM limited to this project's roles/policies + read/write this root's state. Runs `terraform apply`. |
| `<name>-github-deploy` | pushes to `apply_branch` | Push to the project's ECR repos, register task definitions, update the project's ECS services, `RunTask` the listed one-off families (migrations), read their logs, pass the task roles. Runs the app deploy without touching Terraform. |

All three sit under the IAM path `/projects/<project>/`, have a one-hour
maximum session, carry a permissions boundary, and are explicitly denied
access to the `bootstrap/` state and to every S3 object outside their own
state prefix.

## What gets created

- `aws_iam_policy.boundary` `<name>-boundary` (unless `permissions_boundary_arn` is given): a ceiling that forbids creating IAM users/access keys, touching Organizations/billing/account settings, changing roles or policies outside this project, editing or removing the boundary itself, and touching `bootstrap/*` state.
- `aws_iam_role.plan` + `ReadOnlyAccess` + inline `terraform-state`.
- `aws_iam_role.apply` + `PowerUserAccess` + inline `terraform-state` + inline `project-iam`.
- `aws_iam_role.deploy` + inline `deploy`.

IAM has no charge.

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `name` | **yes** | | Prefix, normally `<project>-<environment>`. |
| `project` | **yes** | | Project slug; IAM path `/projects/<project>/`. |
| `github_org` | **yes** | | Repo owner. |
| `github_repo` | **yes** | | Repo name. |
| `github_repository_ids` | no | `null` | `{ owner_id, repo_id }` to also trust the id-based subject form. |
| `oidc_provider_arn` | **yes** | | From `bootstrap` output `oidc_provider_arn`. |
| `state_bucket` | **yes** | | From `bootstrap` output `state_bucket`. |
| `state_key_prefix` | **yes** | | e.g. `acme-shop/prod` (the backend key minus `/terraform.tfstate`). |
| `state_kms_key_arn` | no | `null` | If the bucket uses SSE-KMS. |
| `apply_branch` | no | `main` | Branch allowed to apply/deploy. |
| `github_environment` | no | `null` | GitHub Environment name that may also apply. |
| `ecr_repository_arns` | no | `[]` | Repos the deploy role may push to. |
| `ecs_cluster_arn` | **yes** | | Project cluster. |
| `ecs_service_arns` | no | `[]` | Services the deploy role may update. |
| `pass_role_arns` | no | `[]` | Task + execution role ARNs the deploy role may pass. |
| `run_task_definition_family_arns` | no | `[]` | Family ARNs (`...:task-definition/<family>:*`) the deploy role may `ecs:RunTask` in the cluster (the root's `migrations.tf` tools family). |
| `log_group_arns` | no | `[]` | Log groups the deploy role may read to stream a one-off task's output. |
| `permissions_boundary_arn` | no | `null` | Use an existing boundary instead of creating one. |
| `require_permissions_boundary` | no | `false` | Gate `CreateRole`/`AttachRolePolicy`/`PutRolePolicy` on the boundary being present. |

## Outputs

| Name | Description |
|---|---|
| `plan_role_arn` | `role-to-assume` for the PR workflow. |
| `apply_role_arn` | `role-to-assume` for the apply job. |
| `deploy_role_arn` | `role-to-assume` for the image build/deploy job. |
| `permissions_boundary_arn` | The boundary in use. |
| `subjects` | Exact `sub` claims each role trusts (for debugging). |

## How it is used from a root

```hcl
module "github_oidc_roles" {
  source              = "../../../modules/github_oidc_roles"
  name                = local.name
  project             = var.project
  github_org          = var.github_org
  github_repo         = var.github_repo
  oidc_provider_arn   = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  state_bucket        = "tfstate-123456789012-us-east-1"
  state_key_prefix    = "${var.project}/${var.environment}"
  apply_branch        = "main"
  github_environment  = "prod"
  ecr_repository_arns = [module.web.ecr_repository_arn]
  ecs_cluster_arn     = aws_ecs_cluster.main.arn
  ecs_service_arns    = [module.web.service_arn]
  pass_role_arns      = [module.web.task_role_arn, module.web.execution_role_arn]

  # one-off migration task (see the live root's migrations.tf)
  run_task_definition_family_arns = ["arn:aws:ecs:us-east-1:123456789012:task-definition/${var.project}-${var.environment}-tools:*"]
  log_group_arns                  = [module.web.log_group_arn]
}
```

And in the workflow:

```yaml
permissions:
  id-token: write   # required for OIDC
  contents: read
steps:
  - uses: aws-actions/configure-aws-credentials@v6
    with:
      role-to-assume: arn:aws:iam::123456789012:role/projects/acme-shop/acme-shop-prod-github-plan
      aws-region: us-east-1
```

Note the role ARN includes the path: `role/projects/<project>/<name>`.

## The two GitHub subject formats

The trust policy matches the token's `sub` claim. GitHub has two formats:

- Classic: `repo:acme/shop:ref:refs/heads/main`, `repo:acme/shop:pull_request`, `repo:acme/shop:environment:prod`.
- Immutable ids (repos created after mid-2026 or opted in): `repo:acme@12345/shop@67890:ref:refs/heads/main`, etc.

Set `github_repository_ids` and both forms are trusted, so a repo rename or
GitHub flipping the default does not break CI. Get the ids with
`gh api repos/acme/shop --jq '{owner_id: .owner.id, repo_id: .id}'`.
If an assume fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`,
compare the job's actual claim (add `- run: echo "${{ github.ref }} / ${{ github.event_name }}"`
or decode the token) with `terraform output subjects`.

## `github_environment` must match the workflow

If the apply job in `.github/workflows/terraform.yml` carries
`environment: prod`, GitHub puts `environment:prod` in the token's `sub`
claim **instead of** `ref:refs/heads/main`. The apply role must therefore
trust `repo:org/repo:environment:prod`, which is exactly what
`github_environment = "prod"` adds. A mismatch (workflow says `prod`, module
says `null` or `production`) fails the first apply with
`Not authorized to perform sts:AssumeRoleWithWebIdentity`. `null` is only
right when the apply job has no `environment:` key at all.

## The private-repo GitHub Environments caveat

The usual advice is "put `environment: prod` on the apply job and add
required reviewers so a human approves every apply". **Required reviewers
and wait timers on Environments only work on public repositories, or on
GitHub Enterprise.** On a private repo under Free/Pro/Team, the Environment
still exists, deployment-branch restrictions and environment secrets work,
but nobody is asked to approve anything, and the job just runs.

So for a private repo without Enterprise, your approval gate is:

1. Protected `main` branch requiring a PR review (the plan is posted on the PR).
2. The apply job runs only on `push` to `main` (that is the only subject the apply role trusts).
3. Optionally make the apply workflow `workflow_dispatch` so a human presses the button.

`github_environment` is still worth setting: it scopes environment secrets
and lets you switch on reviewers the day you move to a public repo or
Enterprise, with no AWS change.

## Why PowerUserAccess, and how to tighten later

`terraform apply` for this stack touches ECS, ECR, RDS, ELB, ACM, Route 53,
CloudFront, WAF, Secrets Manager, CloudWatch, Application Auto Scaling,
EventBridge Scheduler, S3, Budgets and Cost Explorer. A hand-written
least-privilege policy for all of that is several hundred lines and breaks
every time a module adds a resource. `PowerUserAccess` (everything except
IAM, Organizations and account settings) is the honest starting point for a
solo developer or small agency; what keeps it safe is:

- the **permissions boundary** (no IAM users, no billing, no touching other projects' roles, cannot remove itself),
- IAM rights limited to roles/policies under `/projects/<project>/` **or named `<name>-*`**,
- state access limited to this root's prefix, with `bootstrap/*` denied outright,
- the trust policy: only this repo, only `main` / the environment.

To tighten later: turn on CloudTrail, run the pipeline for a few weeks, use
IAM Access Analyzer's "generate policy" on the apply role, and swap the
`PowerUserAccess` attachment for the generated policy. Turn on
`require_permissions_boundary = true` once every module that creates IAM
roles for this project (`ecs_service`, `scheduled_task`) passes
`permissions_boundary = module.github_oidc_roles.permissions_boundary_arn`.

## Gotchas

- **Chicken and egg on first apply.** These roles reference ECR/ECS ARNs that
  are created in the same apply. That is fine (Terraform orders it), but it
  means the very first apply of a project must be run by a human, not by
  CI, because the CI roles do not exist yet.
- **The apply role can edit itself and its siblings** (they are under the
  project path). It cannot exceed the boundary while doing so, but if you
  want a stricter split, move this module to a human-only root.
- **Cross-project state isolation is via an object-level Deny**, which also
  denies `s3:GetObject`/`PutObject` on *every other bucket*. Terraform does
  not need object access for anything but state, so this is invisible until
  you add an `aws_s3_object` resource to the root; then add its ARN to the
  `not_resources` list in `state_guard`.
- **Key names in the state bucket are still listable** (`s3:ListBucket` is
  granted bucket-wide because Terraform lists `env:/` during `init`). Only
  object contents are protected.
- **Repository names are case-insensitive on GitHub but the `sub` claim is
  exact** as GitHub stores it. Use the canonical casing from the repo URL.
- **PRs from forks get no OIDC token** (GitHub withholds `id-token: write`
  from fork-triggered `pull_request` runs), so the plan step fails to
  authenticate on them. Plans for outside contributors need a maintainer to
  push the branch to the main repo. The plan role is read-only in any case,
  which is why it is the only role that trusts `pull_request`.
- **Name-prefix scoping is only as good as your slugs.** The apply role may
  manage roles named `<name>-*`; a second project whose slug starts with
  this project's full `<name>` (e.g. `acme-prod-eu` next to `acme`/`prod`)
  would fall inside that pattern. Pick slugs that are not prefixes of each
  other.
- **`max_session_duration` is 1 hour.** A `terraform apply` longer than that
  (large RDS changes) fails mid-way with expired credentials; raise it in
  `main.tf` for that project if it happens.
