# s3_media

Private S3 bucket for uploads/media, optionally served through CloudFront with
Origin Access Control (`enable_cdn`, default on). This is the landing spot for
Vercel Blob objects and files that lived on a Railway volume.

Two modes:

- **`enable_cdn = true`** (images, avatars, public downloads): browsers read
  `https://<media_url>/<key>` through CloudFront; the bucket stays private
  behind OAC.
- **`enable_cdn = false`** (invoices, contracts, PDFs, anything per-user): no
  distribution, no OAC, no certificate. The only way to read an object is the
  app's task role, typically by handing the browser a short-lived presigned GET
  URL. `media_url` and the `distribution_*` outputs are `null`.

## What it creates

| Resource | Notes |
|---|---|
| `aws_s3_bucket` `<name>-media-<account id>` | Account id suffix keeps the name globally unique without random strings. |
| `aws_s3_bucket_public_access_block` | All four blocks on. The bucket is never public. |
| `aws_s3_bucket_ownership_controls` | `BucketOwnerEnforced` (ACLs disabled). |
| `aws_s3_bucket_versioning` | Enabled by default (`enable_versioning`). |
| `aws_s3_bucket_server_side_encryption_configuration` | SSE-S3 (free) or SSE-KMS when `kms_key_arn` is set. |
| `aws_s3_bucket_lifecycle_configuration` | Abort multipart after 7 d, expire old versions after 30 d, clean delete markers. |
| `aws_s3_bucket_cors_configuration` (optional) | GET/HEAD/PUT from `cors_allowed_origins`, exposes `ETag`. |
| `aws_s3_bucket_policy` | Deny non-TLS; with the CDN also allow `cloudfront.amazonaws.com` `s3:GetObject` with `AWS:SourceArn` = this distribution. |
| `aws_acm_certificate` (+ validation, optional) | us-east-1, only when `enable_cdn` and `domain_name` is set. |
| `aws_cloudfront_origin_access_control` (`enable_cdn`) | SigV4, always sign. |
| `aws_cloudfront_distribution` (`enable_cdn`) | S3 REST origin, `Managed-CachingOptimized`, compress, redirect-to-https, HTTP/2+3, IPv6. |
| `aws_route53_record` A/AAAA (optional) | Alias for `domain_name` (CDN only). |
| `data.aws_iam_policy_document.task` | Policy JSON for the app's task role (output only; nothing attached here). |

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Base name; bucket becomes `<name>-media-<account>`. |
| `enable_cdn` | bool | `true` | Create the CloudFront distribution + OAC. `false` = private bucket served by the app with presigned URLs. |
| `domain_name` | string | `null` | Custom CDN hostname. Null = default CloudFront domain. Ignored without the CDN. |
| `hosted_zone_id` | string | `null` | Required when `domain_name` is set. |
| `cors_allowed_origins` | list(string) | `[]` | Origins allowed for browser GET/HEAD/PUT. |
| `kms_key_arn` | string | `null` | Customer-managed key for SSE-KMS. |
| `enable_versioning` | bool | `true` | Keep old versions for rollback. |
| `noncurrent_version_expiration_days` | number | `30` | Retention for old versions. |
| `price_class` | string | `"PriceClass_100"` | CloudFront edge set. |
| `force_destroy` | bool | `false` | Let destroy empty the bucket. |

## Outputs

| Name | Description |
|---|---|
| `bucket_name` | Bucket name for the app's environment. |
| `bucket_arn` | Bucket ARN. |
| `bucket_regional_domain_name` | REST endpoint used as the CloudFront origin. |
| `distribution_id` / `distribution_arn` | For invalidations / policies. `null` when `enable_cdn = false`. |
| `distribution_domain_name` | `dXXXX.cloudfront.net`, or `null` without the CDN. |
| `media_url` | `https://<domain_name or cloudfront domain>`, or `null` without the CDN. |
| `task_policy_json` | Attach to the ECS task role via `ecs_service.task_policy_json`. |

## Cost

- S3 Standard ~$0.023/GB-month plus requests ($0.005 per 1k PUT, $0.0004 per 1k GET).
  5 GB of images is about $0.12/month. Versioning doubles storage only for
  objects you overwrite, and old versions expire after 30 days.
- CloudFront: 1 TB/month out and 10 M requests are always free; S3 -> CloudFront
  transfer is free. Expect $0 for a small site.
- SSE-KMS adds KMS request charges (reduced by the bucket key, which is enabled
  automatically when a key is given). SSE-S3 is free.
- A custom domain costs nothing extra (ACM public certificates are free, alias
  queries are free).

## Gotchas

1. **Wire the task role.** The module only *emits* the policy. In the root:
   `task_policy_json = module.media[0].task_policy_json` on the web (and worker)
   `ecs_service` so uploads work.
2. **Content-Type at upload time.** CloudFront serves whatever metadata S3 has.
   If a bulk copy from Vercel Blob skipped content types, images download as
   `application/octet-stream`; re-copy with `--content-type` or set it in the
   uploader.
3. **`next.config.js` `images.remotePatterns`** must include the new host (and
   the old Blob host during the overlap) or `next/image` returns 400.
4. **KMS key policy.** With `kms_key_arn`, CloudFront's OAC decrypts objects
   using the service principal. The key policy must allow
   `cloudfront.amazonaws.com` `kms:Decrypt` with the same `AWS:SourceArn`
   condition as the bucket policy; that lives with the key, not in this module.
5. **Presigned uploads from the browser** need the CORS rule *and* a presigned
   URL generated by the task role (`@aws-sdk/s3-request-presigner`). The URL
   must target the bucket, not the CDN.
6. **Deleting the bucket.** `terraform destroy` fails on a non-empty bucket
   unless `force_destroy = true`. That is intentional for prod.
7. **OAC vs OAI.** Only OAC is created (OAI is legacy and not allowed on
   flat-rate distributions). Payload/Uploadthing-style adapters that expect a
   public bucket need the `media_url` as their public base instead.
8. **Cache invalidation.** `CachingOptimized` caches for up to a year; use
   unique object keys for new uploads (the usual pattern) and invalidate only
   when overwriting in place.
9. **Switching `enable_cdn` later** is a normal apply: turning it off destroys
   the distribution (existing public URLs stop working, so change the app
   first); turning it on takes ~5 minutes of CloudFront propagation. Presigned
   GET URLs expire after at most 7 days (SigV4 limit); generate them per
   request, not at upload time.
