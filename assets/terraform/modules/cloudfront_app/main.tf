# cloudfront_app: CloudFront in front of the application load balancer.
#
# Why CloudFront at all when the ALB already terminates TLS?
#   - the always-free tier covers 1 TB/month out + 10 M requests, and ALB -> CloudFront transfer is free,
#     so for most small apps the distribution costs $0 and *reduces* the ALB's LCU and egress bill;
#   - /_next/static/* and optimized images are cached at the edge instead of hitting Fargate;
#   - HTTP/3, brotli, Shield Standard DDoS absorption and (optionally) WAF come with it.
# Flat-rate plans (Free $0 / Pro $15 / Business $200 per distribution, Nov 2025) are opt-in from the console
# and change which features are allowed; see README "Flat-rate plans".

locals {
  comment   = coalesce(var.comment, var.name)
  origin_id = "${var.name}-alb"

  # Every hostname the distribution answers for: the primary plus aliases such
  # as www. All of them need a SAN on the certificate and, when the root says
  # so, A/AAAA alias records.
  all_domain_names = concat([var.domain_name], var.additional_domain_names)
  dns_records = var.create_dns_records ? {
    for pair in setproduct(local.all_domain_names, ["A", "AAAA"]) : "${pair[0]}-${pair[1]}" => { name = pair[0], type = pair[1] }
  } : {}

  redirect_aliases = var.redirect_to_primary_domain && length(var.additional_domain_names) > 0
}

# ---------------------------------------------------------------------------
# Managed policies. Looked up by name so the IDs are never copied by hand; the
# well-known IDs are kept in comments for cross-checking against the AWS docs.
# NOTE: all managed names carry the "Managed-" prefix EXCEPT the two
# UseOriginCacheControlHeaders* policies (verified against the provider docs).
# ---------------------------------------------------------------------------
data "aws_cloudfront_cache_policy" "origin_cache_control_qs" {
  name = "UseOriginCacheControlHeaders-QueryStrings" # 4cc15a8a-d715-48a4-82b8-cc0b614638fe
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized" # 658327ea-f89d-4fab-a63d-7e88639e58f6
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled" # 4135ea2d-6df8-44a3-9df3-4b5a84be39ad
}

# Managed-AllViewer = 216adef6-5c7f-47e4-b989-5492eafa07d3,
# Managed-AllViewerAndCloudFrontHeaders-2022-06 = 33f36d7e-f396-46d9-90e0-52428a34d9dc.
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = var.origin_request_policy_name
}

# ---------------------------------------------------------------------------
# Certificate. CloudFront only accepts certificates from us-east-1, whatever
# region the rest of the stack lives in. Provider v6 lets a single resource
# override the region, so no provider alias is needed.
# ---------------------------------------------------------------------------
resource "aws_acm_certificate" "this" {
  region                    = "us-east-1"
  domain_name               = var.domain_name
  subject_alternative_names = var.additional_domain_names
  validation_method         = "DNS"
  key_algorithm             = "RSA_2048"

  tags = { Name = "${var.name}-cloudfront" }

  # A renewal creates a new certificate before the old one is released, so the
  # distribution never points at a deleted ARN.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true # the ALB certificate may have created the same CNAME for the same name
}

resource "aws_acm_certificate_validation" "this" {
  region                  = "us-east-1"
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------------------------------------------------------------------------
# Custom cache policy for the Next.js image optimizer.
# /_next/image?url=...&w=...&q=... must be keyed on exactly those query strings
# plus the Accept header (the optimizer returns AVIF, WebP or the original
# depending on it). Not allowed on Free/Pro flat-rate plans.
# ---------------------------------------------------------------------------
resource "aws_cloudfront_cache_policy" "next_image" {
  count = var.create_image_cache_policy ? 1 : 0

  name        = "${var.name}-next-image"
  comment     = "Next.js /_next/image: key on url,w,q + Accept; honour origin TTL"
  default_ttl = 86400    # used only when the origin sends no Cache-Control; Next always does
  min_ttl     = 0        # let the origin shorten it (images.minimumCacheTTL)
  max_ttl     = 31536000 # one year cap

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true

    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "whitelist"
      headers {
        items = ["Accept"]
      }
    }

    query_strings_config {
      query_string_behavior = "whitelist"
      query_strings {
        items = ["url", "w", "q"]
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Distribution
# ---------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = local.comment
  aliases         = local.all_domain_names
  price_class     = var.price_class
  http_version    = "http2and3"
  is_ipv6_enabled = true
  web_acl_id      = var.enable_waf ? aws_wafv2_web_acl.this[0].arn : null

  # Return as soon as the config is accepted; propagation to every edge takes
  # several minutes and nothing downstream depends on it finishing.
  wait_for_deployment = false

  origin {
    origin_id   = local.origin_id
    domain_name = var.origin_domain_name

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = var.origin_protocol_policy
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = var.origin_read_timeout
      origin_keepalive_timeout = 60
    }
  }

  # Default: everything else (HTML, RSC payloads, server actions). The managed
  # UseOriginCacheControlHeaders-QueryStrings policy keys on Host, cookies and all
  # query strings (incl. _rsc) and caches only what Next.js marks cacheable
  # (s-maxage on static/ISR pages); dynamic pages send private/no-store and are
  # passed through. AllViewer forwards Host and the next-router-* / rsc headers
  # Next.js needs, so the origin sees exactly what the browser sent.
  default_cache_behavior {
    target_origin_id         = local.origin_id
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.origin_cache_control_qs.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

    # The www -> apex redirect is attached to EVERY behavior (this one and the
    # ordered ones below): the ALB listener rule only matches the primary Host,
    # so an alias host that slipped through on /api/* would get the ALB's 404.
    dynamic "function_association" {
      for_each = local.redirect_aliases ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.redirect_to_primary[0].arn
      }
    }
  }

  # Immutable build assets: content-hashed filenames, so cache for a year and
  # ignore cookies/query strings entirely.
  ordered_cache_behavior {
    path_pattern             = var.static_path_pattern
    target_origin_id         = local.origin_id
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_optimized.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

    dynamic "function_association" {
      for_each = local.redirect_aliases ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.redirect_to_primary[0].arn
      }
    }
  }

  # Image optimizer (only when the custom policy exists; otherwise the default
  # behavior handles it).
  dynamic "ordered_cache_behavior" {
    for_each = var.create_image_cache_policy ? [1] : []
    content {
      path_pattern             = var.image_path_pattern
      target_origin_id         = local.origin_id
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS"]
      cached_methods           = ["GET", "HEAD"]
      compress                 = true
      cache_policy_id          = aws_cloudfront_cache_policy.next_image[0].id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

      dynamic "function_association" {
        for_each = local.redirect_aliases ? [1] : []
        content {
          event_type   = "viewer-request"
          function_arn = aws_cloudfront_function.redirect_to_primary[0].arn
        }
      }
    }
  }

  # API / admin / webhooks: never cached, every method, everything forwarded.
  dynamic "ordered_cache_behavior" {
    for_each = toset(var.api_path_patterns)
    content {
      path_pattern             = ordered_cache_behavior.value
      target_origin_id         = local.origin_id
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods           = ["GET", "HEAD"]
      compress                 = true
      cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

      dynamic "function_association" {
        for_each = local.redirect_aliases ? [1] : []
        content {
          event_type   = "viewer-request"
          function_arn = aws_cloudfront_function.redirect_to_primary[0].arn
        }
      }
    }
  }

  dynamic "logging_config" {
    for_each = var.log_bucket == null ? [] : [var.log_bucket]
    content {
      bucket          = logging_config.value
      prefix          = "${var.name}/"
      include_cookies = false
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.this.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = var.minimum_protocol_version
  }

  tags = { Name = var.name }
}

# ---------------------------------------------------------------------------
# Alias host -> primary host redirect at the edge (www.example.com -> example.com).
# A CloudFront Function runs before the cache on every viewer request to the
# default behavior; it is the replacement for the free www redirect Vercel and
# Railway custom domains gave you. Cost: 2 M invocations/month free, then
# $0.10 per million.
# ---------------------------------------------------------------------------
resource "aws_cloudfront_function" "redirect_to_primary" {
  count = local.redirect_aliases ? 1 : 0

  name    = "${var.name}-redirect-to-primary"
  runtime = "cloudfront-js-2.0"
  comment = "301 any alias hostname to ${var.domain_name}"
  publish = true
  code    = <<-JS
    function handler(event) {
      var request = event.request;
      var host = request.headers.host && request.headers.host.value;
      if (host === "${var.domain_name}") {
        return request;
      }
      var parts = [];
      var keys = Object.keys(request.querystring);
      for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        var entry = request.querystring[key];
        if (entry.multiValue) {
          for (var j = 0; j < entry.multiValue.length; j++) {
            parts.push(key + "=" + entry.multiValue[j].value);
          }
        } else {
          parts.push(key + "=" + entry.value);
        }
      }
      var qs = parts.length > 0 ? "?" + parts.join("&") : "";
      return {
        statusCode: 301,
        statusDescription: "Moved Permanently",
        headers: {
          location: { value: "https://${var.domain_name}" + request.uri + qs },
          "cache-control": { value: "max-age=3600" }
        }
      };
    }
  JS
}

# ---------------------------------------------------------------------------
# DNS: alias every public hostname to the distribution (alias queries are free).
# create_dns_records = false is the pre-cutover state: the zone can already be
# authoritative while apex/www still point at the old platform.
# ---------------------------------------------------------------------------
resource "aws_route53_record" "alias" {
  for_each = local.dns_records

  zone_id = var.hosted_zone_id
  name    = each.value.name
  type    = each.value.type

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false # CloudFront aliases do not support health evaluation
  }
}
