variable "name" {
  type        = string
  description = "Base name for every resource, e.g. \"acme-prod\". Resources are named \"<name>-<component>\"."
}

variable "domain_name" {
  type        = string
  description = "Public hostname served by CloudFront (the distribution alias and the ACM certificate CN), e.g. \"app.example.com\"."

  validation {
    condition     = can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a lowercase fully-qualified hostname such as app.example.com."
  }
}

variable "additional_domain_names" {
  type        = list(string)
  description = "Extra hostnames the distribution answers for, e.g. [\"www.example.com\"]. Each becomes an ACM SAN, a distribution alias and (with create_dns_records) an A/AAAA alias record. Must live in hosted_zone_id."
  default     = []

  validation {
    condition     = alltrue([for d in var.additional_domain_names : can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", d))])
    error_message = "additional_domain_names must be lowercase fully-qualified hostnames."
  }
}

variable "redirect_to_primary_domain" {
  type        = bool
  description = "Attach a CloudFront Function (viewer-request) that 301-redirects any additional_domain_names host to domain_name, preserving path and query string (www -> apex). No effect when additional_domain_names is empty. CloudFront Functions: 2 M invocations/month free, then $0.10 per million."
  default     = true
}

variable "create_dns_records" {
  type        = bool
  description = "Create the Route 53 A/AAAA alias records for domain_name and additional_domain_names. false leaves the public names alone (the zone can keep pointing at the old platform until cutover); the ACM validation CNAMEs are always created."
  default     = true
}

variable "hosted_zone_id" {
  type        = string
  description = "Route 53 hosted zone that contains domain_name. Used for ACM DNS validation and the A/AAAA alias records."
}

variable "origin_request_policy_name" {
  type        = string
  description = <<-EOT
    Managed origin request policy used by every behavior.
    "Managed-AllViewer" forwards every viewer header, cookie and query string (Host, webhook signatures, next-router-*).
    "Managed-AllViewerAndCloudFrontHeaders-2022-06" additionally forwards the CloudFront-Viewer-Country / -City /
    -Address / -TLS headers: pick it when the app needs geolocation (the replacement for Vercel's x-vercel-ip-* headers).
    "Managed-AllViewerExceptHostHeader" only if the origin must see its own hostname instead of the viewer's.
  EOT
  default     = "Managed-AllViewer"

  validation {
    condition     = contains(["Managed-AllViewer", "Managed-AllViewerAndCloudFrontHeaders-2022-06", "Managed-AllViewerExceptHostHeader"], var.origin_request_policy_name)
    error_message = "origin_request_policy_name must be Managed-AllViewer, Managed-AllViewerAndCloudFrontHeaders-2022-06 or Managed-AllViewerExceptHostHeader."
  }
}

variable "origin_domain_name" {
  type        = string
  description = <<-EOT
    Hostname CloudFront connects to, normally a Route 53 record such as "origin.app.example.com" that aliases the ALB.
    Do NOT pass the raw ALB DNS name with origin_protocol_policy = "https-only": CloudFront verifies the origin's
    TLS certificate against this hostname, and the ALB's ACM certificate does not cover *.elb.amazonaws.com.
  EOT
}

variable "origin_protocol_policy" {
  type        = string
  description = "How CloudFront talks to the origin. Keep \"https-only\" so the ALB adds X-Forwarded-Proto: https and Next.js sees the right scheme."
  default     = "https-only"

  validation {
    condition     = contains(["https-only", "http-only", "match-viewer"], var.origin_protocol_policy)
    error_message = "origin_protocol_policy must be https-only, http-only or match-viewer."
  }
}

variable "origin_read_timeout" {
  type        = number
  description = "Seconds CloudFront waits for an origin response. 60 is the hard maximum without an AWS Support increase; long-running routes must stream early bytes or bypass CloudFront."
  default     = 60

  validation {
    condition     = var.origin_read_timeout >= 1 && var.origin_read_timeout <= 60
    error_message = "origin_read_timeout must be between 1 and 60 seconds."
  }
}

variable "enable_waf" {
  type        = bool
  description = "Attach an AWS WAF web ACL (managed rule groups + rate limit) to the distribution. Pay-as-you-go cost: about $5/month per web ACL + $1/month per rule or managed group + $0.60 per million requests. Included in CloudFront flat-rate plans."
  default     = false
}

variable "waf_rate_limit" {
  type        = number
  description = "Requests per 5-minute window from one IP before the rate-based rule blocks it. Replaces Vercel's Attack Challenge Mode / Railway's absence of rate limiting."
  default     = 2000

  validation {
    condition     = var.waf_rate_limit >= 10 && var.waf_rate_limit <= 2000000000
    error_message = "waf_rate_limit must be between 10 and 2,000,000,000 (AWS WAF limits)."
  }
}

variable "path_rate_limits" {
  type = list(object({
    path_prefix = string
    limit       = number
    name        = optional(string)
  }))
  description = "Extra WAF rate-based rules scoped to a URI path prefix, evaluated after the global waf_rate_limit: e.g. [{ path_prefix = \"/api/auth/\", limit = 300 }] blocks an IP that sends more than 300 requests under /api/auth/ in 5 minutes. Replaces Vercel Firewall / Railway-less per-route limits. `name` is optional (used in the rule and metric name; defaults to a slug of the prefix). Only applies when enable_waf = true. Each rule costs $1/month."
  default     = []

  validation {
    condition     = alltrue([for r in var.path_rate_limits : r.limit >= 10 && r.limit <= 2000000000 && startswith(r.path_prefix, "/")])
    error_message = "Each path_rate_limits entry needs a path_prefix starting with / and a limit between 10 and 2,000,000,000 (AWS WAF limits)."
  }

  validation {
    condition     = alltrue([for r in var.path_rate_limits : r.name == null || can(regex("^[a-z0-9-]{1,40}$", r.name))])
    error_message = "path_rate_limits names must be kebab-case (a-z, 0-9, hyphens), at most 40 characters."
  }

  validation {
    condition     = length(var.path_rate_limits) <= 9
    error_message = "At most 9 path_rate_limits entries (WAF rule priorities 1-9 are reserved for them)."
  }
}

variable "waf_count_only_rules" {
  type        = list(string)
  description = "AWSManagedRulesCommonRuleSet rules switched to COUNT instead of BLOCK. The defaults false-positive on CMS admin saves (rich text bodies > 8 KB)."
  default     = ["SizeRestrictions_BODY", "CrossSiteScripting_BODY"]
}

variable "price_class" {
  type        = string
  description = "Edge locations to serve from. PriceClass_100 (North America + Europe) is the cheapest per GB; PriceClass_All adds Asia/South America edges at a higher per-GB rate. Irrelevant on flat-rate plans."
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "api_path_patterns" {
  type        = list(string)
  description = "Path patterns that must never be cached (CachingDisabled + all viewer headers). One ordered behavior is created per pattern; the flat-rate Free plan allows 5 behaviors in total."
  default     = ["/api/*", "/admin/*"]
}

variable "static_path_pattern" {
  type        = string
  description = "Path pattern for Next.js immutable build assets, cached with the managed CachingOptimized policy for up to a year."
  default     = "/_next/static/*"
}

variable "image_path_pattern" {
  type        = string
  description = "Path pattern for the Next.js image optimizer. Cached by a custom policy keyed on the url/w/q query strings and the Accept header (AVIF/WebP negotiation)."
  default     = "/_next/image*"
}

variable "create_image_cache_policy" {
  type        = bool
  description = "Create the custom cache policy for image_path_pattern. Custom cache policies are NOT available on the CloudFront Free and Pro flat-rate plans; set this to false there and images fall through to the default behavior (still cached, keyed on all query strings)."
  default     = true
}

variable "log_bucket" {
  type        = string
  description = "Optional S3 bucket domain name (e.g. \"my-logs.s3.amazonaws.com\") for CloudFront standard access logs. The bucket must have ACLs enabled (ObjectWriter ownership). Null disables logging; logs cost S3 storage only."
  default     = null
}

variable "minimum_protocol_version" {
  type        = string
  description = "Minimum TLS version viewers may use. TLSv1.2_2021 is the current recommended policy."
  default     = "TLSv1.2_2021"
}

variable "comment" {
  type        = string
  description = "Optional comment shown in the CloudFront console. Defaults to the name."
  default     = null
}
