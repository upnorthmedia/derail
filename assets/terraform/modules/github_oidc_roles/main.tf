# Three IAM roles that GitHub Actions assumes through OIDC, so CI never holds
# an AWS access key:
#
#   <name>-github-plan    PRs and any branch     read-only + state read + lock
#   <name>-github-apply   pushes to apply_branch  PowerUserAccess + scoped IAM + state write
#   <name>-github-deploy  pushes to apply_branch  push image to ECR + roll the ECS service + run one-off tasks
#
# All three live under the IAM path /projects/<project>/, carry a permissions
# boundary, and can only touch THIS root's state prefix. IAM roles are free.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  iam_path   = "/projects/${var.project}/"

  # GitHub subject claim prefixes. The classic form is "repo:org/repo"; the
  # immutable id-based form "repo:org@123/repo@456" is what newer repos emit.
  # Both are accepted when ids are given, so a repo rename or migration does
  # not lock CI out.
  repo_prefixes = compact([
    "repo:${var.github_org}/${var.github_repo}",
    var.github_repository_ids == null ? "" : "repo:${var.github_org}@${var.github_repository_ids.owner_id}/${var.github_repo}@${var.github_repository_ids.repo_id}",
  ])

  # plan: pull_request events and pushes to any branch (so feature branches
  # can run a plan). Nothing here can change AWS.
  plan_subjects = flatten([
    for p in local.repo_prefixes : ["${p}:pull_request", "${p}:ref:refs/heads/*"]
  ])

  # apply: only the protected branch, plus the GitHub Environment if used.
  # Never a wildcard: a PR from a fork must not be able to apply.
  apply_subjects = flatten([
    for p in local.repo_prefixes : concat(
      ["${p}:ref:refs/heads/${var.apply_branch}"],
      var.github_environment == null ? [] : ["${p}:environment:${var.github_environment}"],
    )
  ])

  deploy_subjects = [for p in local.repo_prefixes : "${p}:ref:refs/heads/${var.apply_branch}"]

  # IAM entities the apply role may manage: anything under this project's
  # path OR named with this root's prefix (the ecs_service / scheduled_task
  # modules name their roles "<name>-<component>-..." without a path).
  managed_role_arns = [
    "arn:${local.partition}:iam::${local.account_id}:role${local.iam_path}*",
    "arn:${local.partition}:iam::${local.account_id}:role/${var.name}-*",
  ]
  managed_policy_arns = [
    "arn:${local.partition}:iam::${local.account_id}:policy${local.iam_path}*",
    "arn:${local.partition}:iam::${local.account_id}:policy/${var.name}-*",
  ]

  # Computed (not referenced) so the boundary policy can deny edits to itself
  # without a dependency cycle.
  created_boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy${local.iam_path}${var.name}-boundary"
  effective_boundary   = var.permissions_boundary_arn == null ? local.created_boundary_arn : var.permissions_boundary_arn

  state_bucket_arn  = "arn:${local.partition}:s3:::${var.state_bucket}"
  state_objects_arn = "${local.state_bucket_arn}/${var.state_key_prefix}/*"
  # Terraform >= 1.10 locks with "<key>.tflock" next to the state object.
  state_lock_arn = "${local.state_bucket_arn}/${var.state_key_prefix}/*.tflock"

  # Actions that grant a role permissions. These are the ones the
  # iam:PermissionsBoundary condition key applies to, so they can be gated on
  # "the role carries our boundary" when require_permissions_boundary is on.
  role_grant_actions = [
    "iam:CreateRole",
    "iam:AttachRolePolicy",
    "iam:PutRolePolicy",
    "iam:PutRolePermissionsBoundary",
  ]
  # Actions that change or remove a role without widening its permissions.
  # iam:PermissionsBoundary is not a valid key for these, so they are never
  # conditioned (a condition on a missing key would simply deny them).
  role_update_actions = [
    "iam:DeleteRole",
    "iam:UpdateRole",
    "iam:UpdateRoleDescription",
    "iam:UpdateAssumeRolePolicy",
    "iam:DetachRolePolicy",
    "iam:DeleteRolePolicy",
    "iam:TagRole",
    "iam:UntagRole",
  ]
  role_mutation_actions = concat(local.role_grant_actions, local.role_update_actions)
  policy_mutation_actions = [
    "iam:CreatePolicy",
    "iam:DeletePolicy",
    "iam:CreatePolicyVersion",
    "iam:DeletePolicyVersion",
    "iam:SetDefaultPolicyVersion",
    "iam:TagPolicy",
    "iam:UntagPolicy",
  ]
}

# -----------------------------------------------------------------------------
# Permissions boundary (created unless one is supplied)
# -----------------------------------------------------------------------------

# A boundary is a ceiling: a role's effective permissions are the
# intersection of its policies and the boundary. Attached to the three
# GitHub roles, it guarantees that even PowerUserAccess + the scoped IAM
# rights below cannot be used to create IAM users, touch billing or
# Organizations, or rewrite roles that belong to another project.
data "aws_iam_policy_document" "boundary" {
  count = var.permissions_boundary_arn == null ? 1 : 0

  statement {
    sid       = "AllowEverythingNotDeniedBelow"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyAccountLevelIdentityAndBilling"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
      "iam:AttachUserPolicy",
      "iam:PutUserPolicy",
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:CreateSAMLProvider",
      "iam:DeleteSAMLProvider",
      "organizations:*",
      "account:*",
      "billing:*",
      "aws-portal:*",
    ]
    resources = ["*"]
  }

  statement {
    sid           = "DenyRoleChangesOutsideProject"
    effect        = "Deny"
    actions       = local.role_mutation_actions
    not_resources = local.managed_role_arns
  }

  statement {
    sid           = "DenyPolicyChangesOutsideProject"
    effect        = "Deny"
    actions       = local.policy_mutation_actions
    not_resources = local.managed_policy_arns
  }

  # Classic escalation: edit or remove the boundary itself. Blocked for every
  # role, including the ones created by this project.
  statement {
    sid    = "DenyTamperingWithBoundary"
    effect = "Deny"
    actions = [
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
    ]
    resources = [local.created_boundary_arn]
  }

  statement {
    sid       = "DenyRemovingAnyBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary", "iam:DeleteUserPermissionsBoundary"]
    resources = ["*"]
  }

  # Only humans apply bootstrap/; nothing in CI may read or write its state.
  statement {
    sid       = "DenyBootstrapState"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = ["${local.state_bucket_arn}/bootstrap/*"]
  }
}

resource "aws_iam_policy" "boundary" {
  count = var.permissions_boundary_arn == null ? 1 : 0

  name        = "${var.name}-boundary"
  path        = local.iam_path
  description = "Permissions boundary for roles belonging to project ${var.project}"
  policy      = data.aws_iam_policy_document.boundary[0].json

  tags = {
    Name = "${var.name}-boundary"
  }
}

# -----------------------------------------------------------------------------
# Trust policies (who may assume which role)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "trust_plan" {
  statement {
    sid     = "GitHubOIDCPlan"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.plan_subjects
    }
  }
}

data "aws_iam_policy_document" "trust_apply" {
  statement {
    sid     = "GitHubOIDCApply"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.apply_subjects
    }
  }
}

data "aws_iam_policy_document" "trust_deploy" {
  statement {
    sid     = "GitHubOIDCDeploy"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.deploy_subjects
    }
  }
}

# -----------------------------------------------------------------------------
# Shared state-access statements (used by plan and apply)
# -----------------------------------------------------------------------------

# Deny object access anywhere EXCEPT this root's state prefix. NotResource is
# the only way to say "nothing else in the state bucket" in an identity
# policy, and it also covers every other bucket. That is fine for CI:
# Terraform configures buckets (bucket-level API) but never reads or writes
# objects except its own state. If you later manage aws_s3_object resources
# from this root, add their ARNs to the not_resources list.
data "aws_iam_policy_document" "state_guard" {
  statement {
    sid    = "DenyObjectsOutsideOwnStatePrefix"
    effect = "Deny"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]
    not_resources = [local.state_objects_arn]
  }

  statement {
    sid       = "DenyBootstrapState"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = ["${local.state_bucket_arn}/bootstrap/*"]
  }

  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }

  dynamic "statement" {
    for_each = var.state_kms_key_arn == null ? [] : [var.state_kms_key_arn]
    content {
      sid       = "UseStateKmsKey"
      effect    = "Allow"
      actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      resources = [statement.value]
    }
  }
}

# -----------------------------------------------------------------------------
# plan role: read-only AWS + read state + take/release the lock
# -----------------------------------------------------------------------------

resource "aws_iam_role" "plan" {
  name                 = "${var.name}-github-plan"
  path                 = local.iam_path
  description          = "GitHub Actions: terraform plan for ${var.name} (PRs and branches)"
  assume_role_policy   = data.aws_iam_policy_document.trust_plan.json
  max_session_duration = 3600
  permissions_boundary = local.effective_boundary

  tags = {
    Name = "${var.name}-github-plan"
  }

  # The boundary ARN above is computed, not referenced, so make the ordering explicit.
  depends_on = [aws_iam_policy.boundary]
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_state" {
  source_policy_documents = [data.aws_iam_policy_document.state_guard.json]

  statement {
    sid       = "ReadOwnState"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = [local.state_objects_arn]
  }

  # plan acquires the state lock too (unless run with -lock=false), so it
  # needs to create and delete the .tflock object, and nothing else.
  statement {
    sid       = "WriteOwnLockfile"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = [local.state_lock_arn]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state.json
}

# -----------------------------------------------------------------------------
# apply role: PowerUserAccess + scoped IAM + read/write own state
# -----------------------------------------------------------------------------

# PowerUserAccess is "everything except IAM/Organizations/account". It is a
# pragmatic ceiling for a solo dev or small agency: Terraform touches ECS,
# RDS, ALB, Route 53, ACM, CloudFront, Secrets Manager, CloudWatch, Budgets
# and more, and enumerating least-privilege for all of them is a project in
# itself. The boundary + the scoped IAM statements below are what stop it
# from escalating. Tighten later by replacing the attachment with a custom
# policy generated from CloudTrail (see README).
resource "aws_iam_role" "apply" {
  name                 = "${var.name}-github-apply"
  path                 = local.iam_path
  description          = "GitHub Actions: terraform apply for ${var.name} (${var.apply_branch} branch${var.github_environment == null ? "" : " / environment ${var.github_environment}"})"
  assume_role_policy   = data.aws_iam_policy_document.trust_apply.json
  max_session_duration = 3600
  permissions_boundary = local.effective_boundary

  tags = {
    Name = "${var.name}-github-apply"
  }

  # The boundary ARN above is computed, not referenced, so make the ordering explicit.
  depends_on = [aws_iam_policy.boundary]
}

resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "apply_state" {
  source_policy_documents = [data.aws_iam_policy_document.state_guard.json]

  statement {
    sid    = "ReadWriteOwnState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [local.state_objects_arn]
  }
}

resource "aws_iam_role_policy" "apply_state" {
  name   = "terraform-state"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_state.json
}

# PowerUserAccess denies all of iam:*, so the apply role needs explicit IAM
# rights to create the task/execution/scheduler roles the project uses.
# Those rights are limited to roles and policies under /projects/<project>/
# or named <name>-*, and (optionally) require every created role to carry
# the boundary.
data "aws_iam_policy_document" "apply_iam" {
  statement {
    sid       = "ReadAnyIam"
    effect    = "Allow"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  # Granting permissions to a role (create it, attach/put a policy): gated on
  # the boundary when require_permissions_boundary is on, so no role in this
  # project can ever exceed the boundary's ceiling.
  statement {
    sid       = "GrantProjectRoles"
    effect    = "Allow"
    actions   = local.role_grant_actions
    resources = local.managed_role_arns

    dynamic "condition" {
      for_each = var.require_permissions_boundary ? [local.effective_boundary] : []
      content {
        test     = "StringEquals"
        variable = "iam:PermissionsBoundary"
        values   = [condition.value]
      }
    }
  }

  # Updating, tagging, detaching from or deleting a project role never widens
  # its permissions, so these are not conditioned.
  statement {
    sid       = "UpdateProjectRoles"
    effect    = "Allow"
    actions   = local.role_update_actions
    resources = local.managed_role_arns
  }

  statement {
    sid       = "ManageProjectPolicies"
    effect    = "Allow"
    actions   = local.policy_mutation_actions
    resources = local.managed_policy_arns
  }

  # Terraform must pass the task/execution/scheduler roles to ECS and
  # EventBridge Scheduler when it registers task definitions and schedules.
  statement {
    sid       = "PassProjectRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.managed_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "ecs-tasks.amazonaws.com",
        "scheduler.amazonaws.com",
        "ecs.amazonaws.com",
      ]
    }
  }

  # Service-linked roles (ECS, RDS, Application Auto Scaling, ...) are
  # created on first use; PowerUserAccess already allows this, listed here
  # so the intent survives if PowerUserAccess is swapped out later.
  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"]
  }
}

resource "aws_iam_role_policy" "apply_iam" {
  name   = "project-iam"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_iam.json
}

# -----------------------------------------------------------------------------
# deploy role: push image, register task definition, update service
# -----------------------------------------------------------------------------

# Separate from apply so an app deploy (docker push + ECS update) does not
# need Terraform or PowerUserAccess. This is the role a "deploy on push to
# main" workflow uses.
resource "aws_iam_role" "deploy" {
  name                 = "${var.name}-github-deploy"
  path                 = local.iam_path
  description          = "GitHub Actions: build, push and deploy images for ${var.name} (${var.apply_branch} branch)"
  assume_role_policy   = data.aws_iam_policy_document.trust_deploy.json
  max_session_duration = 3600
  permissions_boundary = local.effective_boundary

  tags = {
    Name = "${var.name}-github-deploy"
  }

  # The boundary ARN above is computed, not referenced, so make the ordering explicit.
  depends_on = [aws_iam_policy.boundary]
}

data "aws_iam_policy_document" "deploy" {
  # GetAuthorizationToken has no resource-level scope.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = length(var.ecr_repository_arns) > 0 ? [1] : []
    content {
      sid    = "EcrPushPull"
      effect = "Allow"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:ListImages",
      ]
      resources = var.ecr_repository_arns
    }
  }

  # RegisterTaskDefinition does not support resource-level permissions.
  statement {
    sid    = "TaskDefinitions"
    effect = "Allow"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:ListTaskDefinitions",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = length(var.ecs_service_arns) > 0 ? [1] : []
    content {
      sid    = "RollProjectServices"
      effect = "Allow"
      actions = [
        "ecs:DescribeServices",
        "ecs:UpdateService",
      ]
      resources = var.ecs_service_arns
    }
  }

  statement {
    sid       = "DescribeCluster"
    effect    = "Allow"
    actions   = ["ecs:DescribeClusters"]
    resources = [var.ecs_cluster_arn]
  }

  # Lets a workflow show why a deployment is failing (list/describe tasks),
  # limited to this cluster.
  statement {
    sid       = "InspectClusterTasks"
    effect    = "Allow"
    actions   = ["ecs:ListTasks", "ecs:DescribeTasks"]
    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.ecs_cluster_arn]
    }
  }

  # One-off tasks (migrations, the "tools" family): RunTask only for the
  # listed families and only in this cluster. The task definition ARN in the
  # policy ends in ":*" so every revision matches.
  dynamic "statement" {
    for_each = length(var.run_task_definition_family_arns) > 0 ? [1] : []
    content {
      sid       = "RunOneOffTasks"
      effect    = "Allow"
      actions   = ["ecs:RunTask"]
      resources = var.run_task_definition_family_arns

      condition {
        test     = "ArnEquals"
        variable = "ecs:cluster"
        values   = [var.ecs_cluster_arn]
      }
    }
  }

  # RunTask with propagateTags / enableECSManagedTags tags the task at launch.
  dynamic "statement" {
    for_each = length(var.run_task_definition_family_arns) > 0 ? [1] : []
    content {
      sid       = "TagTasksAtLaunch"
      effect    = "Allow"
      actions   = ["ecs:TagResource"]
      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "ecs:CreateAction"
        values   = ["RunTask"]
      }
    }
  }

  # Stream the one-off task's output back into the workflow log.
  dynamic "statement" {
    for_each = length(var.log_group_arns) > 0 ? [1] : []
    content {
      sid    = "ReadTaskLogs"
      effect = "Allow"
      actions = [
        "logs:DescribeLogStreams",
        "logs:GetLogEvents",
        "logs:FilterLogEvents",
      ]
      resources = flatten([for a in var.log_group_arns : [a, "${a}:*"]])
    }
  }

  dynamic "statement" {
    for_each = length(var.pass_role_arns) > 0 ? [1] : []
    content {
      sid       = "PassTaskRoles"
      effect    = "Allow"
      actions   = ["iam:PassRole"]
      resources = var.pass_role_arns

      condition {
        test     = "StringEquals"
        variable = "iam:PassedToService"
        values   = ["ecs-tasks.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
