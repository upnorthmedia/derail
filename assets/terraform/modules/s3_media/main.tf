# s3_media: private S3 bucket, optionally fronted by CloudFront (Origin Access
# Control), for user uploads and other media. Replaces Vercel Blob / Railway
# volumes.
#
# The bucket is never public. With enable_cdn = true (default) browsers read
# through CloudFront (signed by OAC); with enable_cdn = false there is no
# distribution at all and the app serves objects itself through presigned GET
# URLs (private documents, invoices, PDFs). Either way the app writes with its
# task role (policy JSON in outputs) or hands the browser a presigned PUT URL
# (CORS below).

data "aws_caller_identity" "current" {}

locals {
  bucket_name   = "${var.name}-media-${data.aws_caller_identity.current.account_id}"
  origin_id     = "${var.name}-media-s3"
  custom_domain = var.enable_cdn && var.domain_name != null
  cdn_domain    = var.enable_cdn ? (local.custom_domain ? var.domain_name : aws_cloudfront_distribution.this[0].domain_name) : null
}

# ---------------------------------------------------------------------------
# Bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy

  tags = { Name = local.bucket_name }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs disabled; everything via policy
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 is free. SSE-KMS adds ~$0.03 per 10k requests through the bucket key.
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # Versioning must be configured before a noncurrent-version rule is accepted.
  depends_on = [aws_s3_bucket_versioning.this]

  rule {
    id     = "housekeeping"
    status = "Enabled"

    filter {}

    # Half-finished multipart uploads are invisible but billed; drop them.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    # Old versions are only a rollback aid; do not pay for them forever.
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    # Clean up the delete markers left behind once all versions have expired.
    expiration {
      expired_object_delete_marker = true
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "this" {
  count = length(var.cors_allowed_origins) > 0 ? 1 : 0

  bucket = aws_s3_bucket.this.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD", "PUT"]
    allowed_origins = var.cors_allowed_origins
    expose_headers  = ["ETag"] # multipart uploads from the browser need it
    max_age_seconds = 3000
  }
}

# Only CloudFront (this distribution, when it exists) may read; only TLS is
# accepted. Without the CDN the policy is the TLS-only deny and nothing else:
# the task role's identity policy (task_policy_json) is the only way in.
data "aws_iam_policy_document" "bucket" {
  dynamic "statement" {
    for_each = var.enable_cdn ? [1] : []
    content {
      sid       = "AllowCloudFrontOAC"
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = ["${aws_s3_bucket.this.arn}/*"]

      principals {
        type        = "Service"
        identifiers = ["cloudfront.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "AWS:SourceArn"
        values   = [aws_cloudfront_distribution.this[0].arn]
      }
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  # The public access block must exist first or S3 rejects the policy write
  # with a confusing "AccessDenied".
  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ---------------------------------------------------------------------------
# Certificate for the custom domain (CloudFront requires us-east-1).
# ---------------------------------------------------------------------------
resource "aws_acm_certificate" "this" {
  count = local.custom_domain ? 1 : 0

  region            = "us-east-1"
  domain_name       = var.domain_name
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  tags = { Name = "${var.name}-media" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.custom_domain ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = local.custom_domain ? 1 : 0

  region                  = "us-east-1"
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------------------------------------------------------------------------
# CloudFront (enable_cdn = true only)
# ---------------------------------------------------------------------------
data "aws_cloudfront_cache_policy" "caching_optimized" {
  count = var.enable_cdn ? 1 : 0

  name = "Managed-CachingOptimized" # 658327ea-f89d-4fab-a63d-7e88639e58f6
}

# Origin Access Control: CloudFront signs every origin request with SigV4 so
# the bucket can stay fully private (successor to OAI; required by flat-rate plans).
resource "aws_cloudfront_origin_access_control" "this" {
  count = var.enable_cdn ? 1 : 0

  name                              = "${var.name}-media"
  description                       = "OAC for ${local.bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  count = var.enable_cdn ? 1 : 0

  enabled             = true
  comment             = "${var.name} media"
  aliases             = local.custom_domain ? [var.domain_name] : []
  price_class         = var.price_class
  http_version        = "http2and3"
  is_ipv6_enabled     = true
  wait_for_deployment = false

  origin {
    origin_id = local.origin_id
    # REST endpoint (bucket.s3.<region>.amazonaws.com), never the website endpoint.
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.this[0].id
  }

  default_cache_behavior {
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Either the validated custom certificate or the default *.cloudfront.net one.
  viewer_certificate {
    cloudfront_default_certificate = local.custom_domain ? null : true
    acm_certificate_arn            = local.custom_domain ? aws_acm_certificate_validation.this[0].certificate_arn : null
    ssl_support_method             = local.custom_domain ? "sni-only" : null
    minimum_protocol_version       = local.custom_domain ? "TLSv1.2_2021" : null
  }

  tags = { Name = "${var.name}-media" }
}

resource "aws_route53_record" "alias" {
  for_each = local.custom_domain ? toset(["A", "AAAA"]) : toset([])

  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.this[0].domain_name
    zone_id                = aws_cloudfront_distribution.this[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# ---------------------------------------------------------------------------
# IAM policy for the application task role (attach via ecs_service.task_policy_json).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "task" {
  statement {
    sid       = "ListMediaBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid    = "ReadWriteMediaObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == null ? [] : [var.kms_key_arn]
    content {
      sid       = "UseMediaKmsKey"
      effect    = "Allow"
      actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
      resources = [statement.value]
    }
  }
}
