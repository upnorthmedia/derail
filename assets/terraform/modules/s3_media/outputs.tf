output "bucket_name" {
  description = "Name of the media bucket (pass to the app as e.g. MEDIA_BUCKET / S3_BUCKET)."
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "ARN of the media bucket."
  value       = aws_s3_bucket.this.arn
}

output "bucket_regional_domain_name" {
  description = "bucket.s3.<region>.amazonaws.com, the REST endpoint CloudFront uses."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

output "distribution_id" {
  description = "CloudFront distribution ID (for invalidations), or null when enable_cdn = false."
  value       = var.enable_cdn ? aws_cloudfront_distribution.this[0].id : null
}

output "distribution_arn" {
  description = "CloudFront distribution ARN, or null when enable_cdn = false."
  value       = var.enable_cdn ? aws_cloudfront_distribution.this[0].arn : null
}

output "distribution_domain_name" {
  description = "The dXXXX.cloudfront.net hostname of the media distribution, or null when enable_cdn = false."
  value       = var.enable_cdn ? aws_cloudfront_distribution.this[0].domain_name : null
}

output "media_url" {
  description = "Public base URL for media (https://<domain_name> or https://<dXXXX.cloudfront.net>), or null when enable_cdn = false (serve with presigned URLs instead). Put it in next.config images.remotePatterns and your upload adapter."
  value       = local.cdn_domain == null ? null : "https://${local.cdn_domain}"
}

output "task_policy_json" {
  description = "IAM policy document (JSON) granting list/get/put/delete on the bucket (+ KMS when used). Pass to ecs_service.task_policy_json."
  value       = data.aws_iam_policy_document.task.json
}
