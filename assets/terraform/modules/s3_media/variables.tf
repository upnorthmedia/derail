variable "name" {
  type        = string
  description = "Base name, e.g. \"acme-prod\". The bucket is named \"<name>-media-<account id>\" (account id keeps it globally unique)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens (S3 bucket naming rules) and at most 31 characters so the bucket name stays under 63."
  }
}

variable "enable_cdn" {
  type        = bool
  description = "Put a CloudFront distribution (with Origin Access Control) in front of the bucket for public reads: images, avatars, anything a browser loads directly. false creates no distribution, OAC or certificate; the bucket is reachable only through the task role, and the app serves files with presigned GET URLs (private documents, invoices, PDFs). CloudFront is $0 under the always-free tier either way."
  default     = true
}

variable "domain_name" {
  type        = string
  description = "Optional custom hostname for the CDN, e.g. \"cdn.example.com\". Null serves from the default dXXXX.cloudfront.net name (no certificate, no DNS needed). Ignored when enable_cdn = false."
  default     = null
}

variable "hosted_zone_id" {
  type        = string
  description = "Route 53 hosted zone containing domain_name. Required when domain_name is set."
  default     = null

  validation {
    condition     = !var.enable_cdn || var.domain_name == null || var.hosted_zone_id != null
    error_message = "hosted_zone_id is required when enable_cdn = true and domain_name is set (ACM DNS validation and the alias record live there)."
  }
}

variable "cors_allowed_origins" {
  type        = list(string)
  description = "Browser origins allowed to GET/HEAD/PUT objects directly (presigned uploads), e.g. [\"https://app.example.com\"]. Empty list = no CORS configuration."
  default     = []
}

variable "kms_key_arn" {
  type        = string
  description = "Optional customer-managed KMS key for SSE-KMS. Null uses SSE-S3 (AES256, free). With KMS the key policy must also allow the CloudFront service principal to decrypt (see README)."
  default     = null
}

variable "enable_versioning" {
  type        = bool
  description = "Keep previous object versions for 30 days (cheap rollback for accidental overwrites/deletes). Costs storage for the old versions only."
  default     = true
}

variable "noncurrent_version_expiration_days" {
  type        = number
  description = "Days to keep old object versions when versioning is enabled."
  default     = 30

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1
    error_message = "noncurrent_version_expiration_days must be at least 1."
  }
}

variable "price_class" {
  type        = string
  description = "CloudFront edge locations (enable_cdn = true only). PriceClass_100 (North America + Europe) is the cheapest per GB."
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "force_destroy" {
  type        = bool
  description = "Allow `terraform destroy` to delete a non-empty bucket. Keep false in prod; flip to true only when decommissioning."
  default     = false
}
