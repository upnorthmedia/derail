output "distribution_id" {
  description = "CloudFront distribution ID (use with `aws cloudfront create-invalidation --distribution-id`)."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  description = "CloudFront distribution ARN."
  value       = aws_cloudfront_distribution.this.arn
}

output "distribution_domain_name" {
  description = "The dXXXX.cloudfront.net hostname. domain_name aliases it."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "distribution_hosted_zone_id" {
  description = "Route 53 hosted zone ID of the distribution, for alias records created elsewhere."
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}

output "certificate_arn" {
  description = "ARN of the validated us-east-1 ACM certificate used by the distribution."
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "web_acl_arn" {
  description = "ARN of the WAF web ACL, or null when enable_waf = false."
  value       = var.enable_waf ? aws_wafv2_web_acl.this[0].arn : null
}

output "domain_names" {
  description = "Every hostname the distribution serves: domain_name first, then additional_domain_names."
  value       = local.all_domain_names
}

output "app_url" {
  description = "Public URL of the application through CloudFront."
  value       = "https://${var.domain_name}"
}
