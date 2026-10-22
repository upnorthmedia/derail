# cloudfront_app

CloudFront distribution in front of the application load balancer, tuned for a
Next.js (or any SSR) app: immutable static assets cached for a year, the image
optimizer keyed on its query strings, API/admin paths never cached, everything
else cached only when the origin says so. Optional AWS WAF web ACL.

## What it creates

| Resource | Notes |
|---|---|
| `aws_acm_certificate` + `aws_acm_certificate_validation` | In **us-east-1** (`region = "us-east-1"` on the resource; no provider alias). DNS-validated through Route 53. |
| `aws_route53_record.cert_validation` | Validation CNAMEs, `allow_overwrite = true` because the ALB module validates the same name. |
| `aws_cloudfront_cache_policy.next_image` (optional) | Keys on `url`, `w`, `q` query strings + `Accept` header. TTL 0 / 86400 / 1 y. |
| `aws_cloudfront_distribution` | Custom origin (ALB), HTTP/2 + HTTP/3, IPv6, `redirect-to-https`, brotli/gzip. |
| `aws_wafv2_web_acl` (optional) | Scope `CLOUDFRONT`, us-east-1. Global rate limit, per-path rate limits (`path_rate_limits`), IP reputation, Common Rule Set (two body rules in COUNT), Known Bad Inputs. |
| `aws_cloudfront_function.redirect_to_primary` (optional) | Viewer-request function that 301s any `additional_domain_names` host to `domain_name` (www -> apex), keeping path and query string. Attached to every behavior. |
| `aws_route53_record.alias` | A + AAAA alias for `domain_name` and each of `additional_domain_names` -> distribution. Skipped when `create_dns_records = false` (pre-cutover). |

### Cache behaviors (in evaluation order)

| Path | Cache policy | Origin request policy | Methods |
|---|---|---|---|
| `static_path_pattern` (`/_next/static/*`) | `Managed-CachingOptimized` | `origin_request_policy_name` | GET/HEAD/OPTIONS |
| `image_path_pattern` (`/_next/image*`) | custom `<name>-next-image` | `origin_request_policy_name` | GET/HEAD/OPTIONS |
| each of `api_path_patterns` (`/api/*`, `/admin/*`) | `Managed-CachingDisabled` | `origin_request_policy_name` | all |
| default `*` | `UseOriginCacheControlHeaders-QueryStrings` | `origin_request_policy_name` | all (GET/HEAD cached) |

`origin_request_policy_name` defaults to `Managed-AllViewer` (not
`AllViewerExceptHostHeader`) so the `Host` header reaching the app is the public
hostname: `headers().get("host")`, `metadataBase`, a CMS `serverURL` fallback and
auth-library origin checks all agree with what the browser sees. Set it to
`Managed-AllViewerAndCloudFrontHeaders-2022-06` when the app needs
`CloudFront-Viewer-Country`, `CloudFront-Viewer-Address` or the other
`CloudFront-Viewer-*` headers (the replacement for Vercel's `x-vercel-ip-*`).

Managed policies are resolved by name through data sources so no IDs are
hard-coded; the well-known IDs are in comments in `main.tf` for cross-checking.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Base name, e.g. `acme-prod`. |
| `domain_name` | string | required | Primary public hostname (alias + certificate CN). |
| `additional_domain_names` | list(string) | `[]` | Extra hostnames (e.g. `["www.example.com"]`): ACM SANs + aliases + A/AAAA records. |
| `redirect_to_primary_domain` | bool | `true` | 301 every `additional_domain_names` host to `domain_name` with a CloudFront Function. No effect when the list is empty. |
| `create_dns_records` | bool | `true` | Create the A/AAAA alias records. `false` = pre-cutover (zone keeps pointing at the old platform); validation CNAMEs are always created. |
| `hosted_zone_id` | string | required | Route 53 zone for validation and alias records. |
| `origin_request_policy_name` | string | `"Managed-AllViewer"` | Or `Managed-AllViewerAndCloudFrontHeaders-2022-06` (adds `CloudFront-Viewer-*` geo/TLS headers) or `Managed-AllViewerExceptHostHeader`. |
| `origin_domain_name` | string | required | Hostname CloudFront connects to (see gotcha 1). |
| `origin_protocol_policy` | string | `"https-only"` | `https-only`, `http-only` or `match-viewer`. |
| `origin_read_timeout` | number | `60` | 1-60 s; the hard CloudFront maximum without a Support increase. |
| `enable_waf` | bool | `false` | Attach the WAF web ACL. |
| `waf_rate_limit` | number | `2000` | Requests per IP per 5 minutes before blocking (global). |
| `path_rate_limits` | list(object) | `[]` | `[{ path_prefix = "/api/auth/", limit = 300, name = "auth" }]` (`name` optional): path-scoped rate rules at priorities 1-9, $1/month each. Max 9. |
| `waf_count_only_rules` | list(string) | `["SizeRestrictions_BODY", "CrossSiteScripting_BODY"]` | Common Rule Set rules demoted to COUNT. |
| `price_class` | string | `"PriceClass_100"` | `PriceClass_100` / `_200` / `_All`. |
| `api_path_patterns` | list(string) | `["/api/*", "/admin/*"]` | Never-cached paths (one behavior each). |
| `static_path_pattern` | string | `"/_next/static/*"` | Immutable assets. |
| `image_path_pattern` | string | `"/_next/image*"` | Image optimizer. |
| `create_image_cache_policy` | bool | `true` | Set `false` on Free/Pro flat-rate plans (custom policies not allowed). |
| `log_bucket` | string | `null` | S3 bucket domain name for standard logs. |
| `minimum_protocol_version` | string | `"TLSv1.2_2021"` | Viewer TLS policy. |
| `comment` | string | `null` | Console comment; defaults to `name`. |

## Outputs

| Name | Description |
|---|---|
| `distribution_id` | For `aws cloudfront create-invalidation`. |
| `distribution_arn` | Distribution ARN. |
| `distribution_domain_name` | `dXXXX.cloudfront.net`. |
| `distribution_hosted_zone_id` | For alias records created elsewhere. |
| `certificate_arn` | The validated us-east-1 certificate. |
| `web_acl_arn` | WAF web ACL ARN, `null` when disabled. |
| `domain_names` | `[domain_name, ...additional_domain_names]`. |
| `app_url` | `https://<domain_name>`. |

## Cost

- **Pay-as-you-go**: always-free 1 TB/month data out + 10 M requests; beyond that
  about $0.085/GB and $0.01 per 10k HTTPS requests (North America/Europe). Origin
  fetches from the ALB are free. For a small app this is $0.
- **WAF (PAYG)**: ~$5/month per web ACL + $1/month per rule/managed group + $0.60
  per million requests. This ACL is 4 rules, so about $9/month plus requests,
  plus $1/month per `path_rate_limits` entry.
- **CloudFront Functions** (the www redirect): 2 M invocations/month free, then
  $0.10 per million. Invisible for a small site.
- **Flat-rate plans** (per distribution, since Nov 2025): Free $0 (1 M requests,
  100 GB, 5 WAF rules, 5 behaviors, no custom cache policies), Pro $15 (10 M
  requests, 50 TB, 25 rules, 10 behaviors), Business $200 (custom policies,
  VPC origins, Bot Control). Not available on AWS Free-plan accounts. A web ACL
  is mandatory on a flat-rate distribution. The plan is chosen in the console,
  not in Terraform; this module's defaults (4 behaviors with the image policy
  off, 4 WAF rules) fit inside the Free plan when `create_image_cache_policy = false`.
- `price_class`: `PriceClass_100` keeps traffic on the cheapest edges; viewers
  elsewhere are still served, just from farther away.

## Gotchas

1. **`origin_domain_name` must be covered by the ALB's certificate.** With
   `origin_protocol_policy = "https-only"` CloudFront validates the origin's TLS
   certificate against the origin hostname. Pointing at the raw
   `*.elb.amazonaws.com` name yields HTTP 502 `OriginSSLHandshakeError`. The root
   creates `origin.<domain>` as a Route 53 alias to the ALB and adds it to the
   ALB certificate's SANs.
2. **The ALB listener rule must match the public `Host`.** `AllViewer` forwards
   the browser's `Host` (`app.example.com`), so the ECS service's `host_headers`
   must contain `domain_name`, not `origin.<domain>`.
3. **60-second origin timeout.** Routes that take longer than
   `origin_read_timeout` get a 504 from CloudFront even though the ALB would
   have waited. Stream early bytes (Suspense) or move long jobs to a worker.
4. **Cookie-keyed caching.** The default cache policy includes all cookies in
   the key, so logged-in HTML variants never collide, at the cost of hit rate.
   Static/ISR pages must send `s-maxage` (Next.js does) to be cached at all.
5. **Vercel-only headers are gone.** Nothing sets `x-vercel-*`; grep the app
   for them. `X-Forwarded-For` contains the viewer IP first, then the CloudFront
   edge IP; use the first entry. For country/city/TLS details set
   `origin_request_policy_name = "Managed-AllViewerAndCloudFrontHeaders-2022-06"`
   and read `CloudFront-Viewer-Country` / `CloudFront-Viewer-Address`.
6. **Set `compress: false` in `next.config.js`.** CloudFront compresses on the
   edge; double compression wastes CPU on Fargate.
7. **WAF false positives.** The two body rules are in COUNT because Payload /
   rich-text admin saves regularly trip them. Watch the `<name>-common-rule-set`
   CloudWatch metric for a week before promoting them back to BLOCK (remove
   them from `waf_count_only_rules`).
8. **Origin verification is a hardening step, not in v1.** Anyone who learns
   the ALB hostname can bypass CloudFront (and the WAF). Harden later by (a)
   restricting the ALB security group to the `com.amazonaws.global.cloudfront.origin-facing`
   prefix list and (b) sending a secret `X-Origin-Verify` custom header that an
   ALB listener rule requires. Both are additive changes to the ALB module.
9. **Invalidation after deploys** is unnecessary for `/_next/static/*`
   (content-hashed) but needed if you change pages with long `s-maxage`:
   `aws cloudfront create-invalidation --distribution-id <id> --paths "/*"`
   (first 1,000 paths/month free).
10. **Logging bucket** must allow ACLs (`BucketOwnerPreferred` ownership);
    CloudFront standard logging (legacy) writes with the `awslogsdelivery` ACL.
11. **`create_dns_records = false` still writes the ACM validation CNAMEs** into
    the Route 53 zone. If the zone is not yet authoritative (NS not moved), the
    certificate stays `PENDING_VALIDATION` and `aws_acm_certificate_validation`
    times out after ~75 minutes. Either delegate the zone first, or copy the
    CNAMEs (`aws acm describe-certificate`) to the old DNS provider by hand.
12. **The www redirect runs at the edge, not in the app.** It only fires for
    hosts in `additional_domain_names`; the primary host passes through
    untouched. Adding a hostname later re-issues the certificate (new SAN) and
    redeploys the distribution: a normal apply, ~5 minutes.
