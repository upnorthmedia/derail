# alb_https

An internet-facing Application Load Balancer with a free, auto-renewing ACM certificate, HTTP -> HTTPS
redirect and a Route 53 alias. It routes nothing by itself: each `ecs_service` adds a host-header
listener rule, which is also how one ALB can serve several projects.

## What it creates

| Resource | Purpose |
|---|---|
| `aws_acm_certificate` + `aws_route53_record` (validation) + `aws_acm_certificate_validation` | DNS-validated certificate for `domain_name` and `additional_domain_names`; waits until ISSUED |
| `aws_security_group` + rules | 80/443 in from `0.0.0.0/0` and `::/0`; all egress |
| `aws_lb` | Application LB, HTTP/2, `drop_invalid_header_fields`, defensive desync mitigation, optional access logs |
| `aws_lb_listener` :80 | 301 redirect to HTTPS |
| `aws_lb_listener` :443 | `ELBSecurityPolicy-TLS13-1-2-2021-06`; default action is a fixed `404 no rule matched` |
| `aws_route53_record` A (+ AAAA when dualstack) | Alias `domain_name` -> ALB, only when `create_dns_record = true` |

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Base name (<= 28 chars); ALB is `<name>-alb` |
| `vpc_id` | string | required | VPC for the security group |
| `public_subnet_ids` | list(string) | required | Public subnets, >= 2 AZs |
| `domain_name` | string | required | Primary hostname, e.g. `app.example.com` |
| `hosted_zone_id` | string | required | Route 53 zone containing the hostnames |
| `additional_domain_names` | list(string) | `[]` | Extra SANs on the certificate (same zone); no DNS records are created for them |
| `idle_timeout` | number | `60` | Idle connection timeout (1-4000 s) |
| `enable_deletion_protection` | bool | `false` | Refuse API deletes of the ALB |
| `access_logs_bucket` | string | `null` | S3 bucket for access logs (needs an ELB log-delivery bucket policy) |
| `create_dns_record` | bool | `true` | Create the alias record(s). The live root passes `!enable_cloudfront && traffic_target == "aws"`: `false` while CloudFront owns the name or before DNS cutover |
| `internal` | bool | `false` | Internal ALB instead of internet-facing |
| `tags` | map(string) | `{}` | Extra tags on the load balancer (merged over `Name`). `platform/` sets `Shared = "true"` |
| `ip_address_type` | string | `"ipv4"` | `"dualstack"` adds IPv6 + an AAAA record, but the subnets must have IPv6 CIDRs |

## Outputs

| Name | Description |
|---|---|
| `alb_arn` | Load balancer ARN |
| `alb_arn_suffix` | `app/<name>/<id>`: CloudWatch `LoadBalancer` dimension / autoscaling resource label prefix |
| `alb_dns_name` | Public DNS name (CloudFront origin) |
| `alb_zone_id` | Hosted zone of the ALB for alias records |
| `https_listener_arn` | Attach `aws_lb_listener_rule`s here |
| `security_group_id` | Allow your container port from this SG only |
| `certificate_arn` | The validated certificate |

## Cost (us-east-1, Oct 2026)

| Item | Monthly |
|---|---|
| ALB hours ($0.0225/h) | ~$16.43 |
| LCU-hours ($0.008/LCU-h; a small app uses < 1 LCU) | ~$1-5 |
| Public IPv4, one per AZ ($0.005/h each) | ~$7.30 for 2 AZs |
| ACM certificate | free |
| Route 53 alias queries | free (the zone itself is $0.50/mo) |
| Access logs | S3 storage only |

**Total ~$25-28/mo**, the biggest fixed line item of a small stack. New accounts get 750 ALB hours/month
free for 12 months (or $200 credits under the 2025 free-tier model). If you run several small projects,
create one ALB in a shared root and give each project its own certificate + listener rule instead of an
ALB each: that is exactly what the `platform/` root does (`name = <platform_name>`, tagged
`Shared = "true"`), and `live/<project>/<env>` with `shared_alb = true` finds it by the tags
`Name = "<platform_name>-alb"` / `Shared = "true"`, attaches its own certificate to the :443 listener
with `aws_lb_listener_certificate` (SNI) and adds its host-header rule at a unique priority.

## Discovery tags (for sharing)

| Resource | Tag | Value |
|---|---|---|
| `aws_lb` | `Name` | `<name>-alb` (plus anything in `var.tags`) |
| `aws_security_group` | `Name` | `<name>-alb` |
| `aws_lb_listener` :443 | `Name` | `<name>-https` (project roots look it up by `load_balancer_arn` + `port = 443` instead) |

## Gotchas

- **The zone must already be delegated.** DNS validation only succeeds if the Route 53 zone is
  authoritative for `domain_name` on the public internet. If the apex is still at another registrar,
  delegate the subdomain (NS record) or move the zone first; otherwise `aws_acm_certificate_validation`
  hangs for ~45 minutes and fails.
- **Wildcards:** `additional_domain_names = ["*.example.com"]` with `domain_name = "example.com"` produces
  the same validation CNAME twice; `allow_overwrite = true` handles that.
- **Changing `domain_name` replaces the certificate.** `create_before_destroy` on the certificate means
  the listener swaps to the new cert before the old one is deleted; expect a few minutes of validation.
- **`ip_address_type = "dualstack"` fails at create time** if the public subnets have no IPv6 CIDR
  (the default `network/` root does not allocate one). Stay on `ipv4` unless you added IPv6 to the VPC.
- **Access logs bucket policy:** the bucket must allow `s3:PutObject` from the ELB account for your
  region (or the `logdelivery.elasticloadbalancing.amazonaws.com` principal in newer regions); the ALB
  creation fails with "Access Denied for bucket" otherwise.
- **404 on the bare DNS name is expected.** The ALB only forwards requests whose `Host` header matches a
  rule. Test with `curl -H "Host: app.example.com" https://<alb_dns_name> -k` before DNS cuts over.
- **The security group is intentionally open on 80/443.** Protection against bots belongs in WAF
  (see `cloudfront_app`) or in rate limits in the app; the ALB SG is not the place.
- **Behind CloudFront** set `create_dns_record = false` (CloudFront owns the hostname) and keep the
  certificate here anyway: CloudFront talks to the ALB over HTTPS and needs a valid certificate for the
  origin hostname.
- **Before DNS cutover** the live root also passes `create_dns_record = false` (`traffic_target = "old"`)
  so the public name keeps pointing at the old platform while the ALB, certificate and services are
  already up; flipping `traffic_target` to `"aws"` creates the alias record in one apply.
- **The validation CNAMEs are written regardless of `create_dns_record`.** If the Route 53 zone is not
  authoritative yet, the certificate stays `PENDING_VALIDATION` and `aws_acm_certificate_validation`
  times out: delegate the zone first, or copy the CNAMEs to the current DNS provider by hand.
