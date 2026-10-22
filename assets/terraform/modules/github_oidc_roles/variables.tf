variable "name" {
  type        = string
  description = "Name prefix, normally \"<project>-<environment>\". Roles are named \"<name>-github-plan|apply|deploy\"."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "project" {
  type        = string
  description = "Project slug. IAM roles and policies live under the path /projects/<project>/ and the apply role may only manage IAM entities under that path (or named <name>-*)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}$", var.project))
    error_message = "project must be 2-23 chars, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "github_org" {
  type        = string
  description = "GitHub organisation or user that owns the repository (the \"acme\" in github.com/acme/shop)."

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", var.github_org))
    error_message = "github_org must be a valid GitHub owner name (alphanumeric and hyphens, max 39 chars)."
  }
}

variable "github_repo" {
  type        = string
  description = "Repository name without the owner (the \"shop\" in github.com/acme/shop)."

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{1,100}$", var.github_repo))
    error_message = "github_repo must be a valid GitHub repository name."
  }
}

variable "github_repository_ids" {
  type = object({
    owner_id = number
    repo_id  = number
  })
  description = <<-EOT
    Optional numeric ids of the owner and repository. When set, the trust policies ALSO accept
    GitHub's immutable subject form "repo:<org>@<owner_id>/<repo>@<repo_id>:...", which repositories
    created after mid-2026 (or opted in) use instead of the name-based form. Find them with:
      gh api repos/<org>/<repo> --jq '{owner_id: .owner.id, repo_id: .id}'
    null keeps only the classic "repo:<org>/<repo>:..." form.
  EOT
  default     = null
}

variable "oidc_provider_arn" {
  type        = string
  description = "ARN of the account's GitHub OIDC provider (bootstrap output oidc_provider_arn)."

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be the ARN of an IAM OIDC provider for token.actions.githubusercontent.com."
  }
}

variable "state_bucket" {
  type        = string
  description = "Name of the Terraform state bucket (bootstrap output state_bucket)."
}

variable "state_key_prefix" {
  type        = string
  description = "Key prefix of this root's state inside the bucket, e.g. \"acme-shop/prod\" when the backend key is \"acme-shop/prod/terraform.tfstate\". The CI roles can only read/write objects under this prefix."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_./-]*[A-Za-z0-9]$", var.state_key_prefix)) && !startswith(var.state_key_prefix, "bootstrap")
    error_message = "state_key_prefix must look like \"<project>/<env>\" (no leading or trailing slash) and must not be the reserved bootstrap prefix."
  }
}

variable "state_kms_key_arn" {
  type        = string
  description = "KMS key ARN if the state bucket uses SSE-KMS (bootstrap state_kms_key_arn); null for SSE-S3."
  default     = null
}

variable "apply_branch" {
  type        = string
  description = "Branch whose pushes may assume the apply and deploy roles. Protect this branch in GitHub."
  default     = "main"
}

variable "github_environment" {
  type        = string
  description = "Optional GitHub Environment name (e.g. \"prod\"). When set, jobs running with `environment: <name>` may also assume the apply role, which lets you gate applies behind required reviewers (public repos or GitHub Enterprise only, see README)."
  default     = null
}

variable "ecr_repository_arns" {
  type        = list(string)
  description = "ECR repository ARNs the deploy role may push to (ecs_service output ecr_repository_arn). Empty list = no push rights."
  default     = []
}

variable "ecs_cluster_arn" {
  type        = string
  description = "ARN of the ECS cluster the deploy role may describe and run deployments in."
}

variable "ecs_service_arns" {
  type        = list(string)
  description = "ECS service ARNs the deploy role may update (web, worker). Empty list = deploy role cannot trigger deployments."
  default     = []
}

variable "pass_role_arns" {
  type        = list(string)
  description = "IAM role ARNs the deploy role may pass to ECS when registering task definitions: the task role and execution role of every service it deploys."
  default     = []
}

variable "run_task_definition_family_arns" {
  type        = list(string)
  description = "Task definition FAMILY ARNs (\"arn:aws:ecs:<region>:<account>:task-definition/<family>:*\") the deploy role may `ecs:RunTask` in ecs_cluster_arn, e.g. the migrations/tools family. Empty list = no RunTask rights."
  default     = []

  validation {
    condition     = alltrue([for a in var.run_task_definition_family_arns : can(regex("^arn:aws[a-z-]*:ecs:[a-z0-9-]+:[0-9]{12}:task-definition/[A-Za-z0-9_-]+:\\*$", a))])
    error_message = "run_task_definition_family_arns entries must be family ARNs ending in \":*\" (every revision), e.g. arn:aws:ecs:us-east-1:123456789012:task-definition/acme-prod-tools:*."
  }
}

variable "log_group_arns" {
  type        = list(string)
  description = "CloudWatch Logs group ARNs the deploy role may read (logs:GetLogEvents / FilterLogEvents / DescribeLogStreams) to stream a one-off task's output into the workflow. Empty list = no log access."
  default     = []
}

variable "permissions_boundary_arn" {
  type        = string
  description = "ARN of an existing permissions boundary policy to use. null (default) creates one named \"<name>-boundary\" under /projects/<project>/ that blocks IAM user creation, Organizations/billing access and IAM changes outside this project."
  default     = null
}

variable "require_permissions_boundary" {
  type        = bool
  description = <<-EOT
    When true, the apply role may only create roles or attach policies to roles that carry the
    permissions boundary (IAM condition iam:PermissionsBoundary). This is the strongest guard
    against privilege escalation, but it means every module that creates IAM roles for this
    project must set permissions_boundary = <this module's output>. The ecs_service and
    scheduled_task modules do not take that input yet, so the default is false; the boundary is
    still created and attached to the three GitHub roles themselves.
  EOT
  default     = false
}
