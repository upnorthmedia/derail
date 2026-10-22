output "state_bucket" {
  description = "Name of the S3 bucket that holds Terraform state for every root in this account. Put it in each root's backend.tf."
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket (needed by modules/github_oidc_roles for the CI roles' state permissions)."
  value       = aws_s3_bucket.tfstate.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider, or null when enable_github_oidc = false. Pass it to modules/github_oidc_roles."
  value       = var.enable_github_oidc ? aws_iam_openid_connect_provider.github[0].arn : null
}

output "alerts_topic_arn" {
  description = "ARN of the account-wide SNS alerts topic."
  value       = aws_sns_topic.alerts.arn
}

output "account_id" {
  description = "AWS account id this root was applied to (handy for filling in backend.tf files)."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "Region the state bucket lives in."
  value       = data.aws_region.current.region
}

output "backend_config_snippet" {
  description = "Ready-to-paste backend block for other roots; change the key per root."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${aws_s3_bucket.tfstate.id}"
        key          = "<project>/<environment>/terraform.tfstate"
        region       = "${data.aws_region.current.region}"
        use_lockfile = true
        encrypt      = true${var.state_kms_key_arn == null ? "" : "\n    kms_key_id   = \"${var.state_kms_key_arn}\""}
      }
    }
  EOT
}
