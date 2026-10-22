output "plan_role_arn" {
  description = "Role for `terraform plan` on pull requests and branches. Use as role-to-assume in the PR workflow."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Role for `terraform apply` from the protected branch / GitHub Environment."
  value       = aws_iam_role.apply.arn
}

output "deploy_role_arn" {
  description = "Role for building, pushing and deploying container images (no Terraform rights)."
  value       = aws_iam_role.deploy.arn
}

output "permissions_boundary_arn" {
  description = "ARN of the permissions boundary attached to the three roles (created here unless permissions_boundary_arn was supplied). Pass it to modules that create IAM roles for this project once require_permissions_boundary is turned on."
  value       = local.effective_boundary
}

output "subjects" {
  description = "The exact GitHub OIDC subject claims each role trusts; useful when debugging \"Not authorized to perform sts:AssumeRoleWithWebIdentity\"."
  value = {
    plan   = local.plan_subjects
    apply  = local.apply_subjects
    deploy = local.deploy_subjects
  }
}
