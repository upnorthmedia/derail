# DNS and the cutover switch.
#
# The certificates (ALB and CloudFront) are validated by CNAMEs Terraform writes
# into a Route 53 zone, and cutover must be a one-minute, reversible record
# change rather than a nameserver move. So the sequence is:
#
#   T-7  create_hosted_zone = true (or use an existing zone), copy every record
#        from the old provider into extra_dns_records and the public hostnames
#        into old_platform_records, apply, then point the registrar's NS at
#        the zone's name servers (output hosted_zone_name_servers). Traffic is
#        unchanged: the zone still answers with the old platform's addresses.
#        Certificates issue now, because the validation CNAMEs are authoritative.
#   T-0  traffic_target = "aws", apply. The old_platform_records disappear and
#        the alias records to CloudFront / the ALB appear. 60 s TTL.
#   Roll back: traffic_target = "old", apply.
#
# origin.<domain> is not user-facing, so it exists from the first apply.

resource "aws_route53_zone" "this" {
  count = var.create_hosted_zone ? 1 : 0

  name    = var.hosted_zone_name
  comment = "${var.project}: public zone managed by live/${var.project}/${var.environment}"

  # Deleting the zone changes its NS set; a re-created zone gets different name
  # servers and the registrar delegation breaks. Nobody wants that by accident.
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = var.hosted_zone_name }
}

# ---------------------------------------------------------------------------
# Pre-cutover: the public hostnames keep resolving to the old platform.
# ---------------------------------------------------------------------------
resource "aws_route53_record" "old_platform" {
  for_each = local.dns_points_to_aws ? {} : var.old_platform_records

  zone_id = local.hosted_zone_id
  name    = each.key
  type    = each.value.type
  ttl     = each.value.ttl
  records = each.value.records
}

# ---------------------------------------------------------------------------
# Everything else that lived at the old DNS provider (mail, verifications).
# ---------------------------------------------------------------------------
resource "aws_route53_record" "extra" {
  for_each = var.extra_dns_records

  zone_id = local.hosted_zone_id
  name    = coalesce(each.value.name, each.key)
  type    = each.value.type
  ttl     = each.value.ttl
  records = each.value.records
}

# ---------------------------------------------------------------------------
# origin.<domain> -> ALB. CloudFront connects to this name (it is on the ALB
# certificate); it is never shown to users, so it is independent of the switch.
# ---------------------------------------------------------------------------
resource "aws_route53_record" "origin" {
  for_each = var.enable_cloudfront ? toset(["A", "AAAA"]) : toset([])

  zone_id = local.hosted_zone_id
  name    = local.origin_domain_name
  type    = each.value

  # The project's own ALB, or the shared platform ALB (locals.tf).
  alias {
    name                   = local.alb_dns_name
    zone_id                = local.alb_zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------------------
# Without CloudFront: additional hostnames (www) alias the ALB too, and an ALB
# listener rule answers them with a 301 to domain_name. With CloudFront on, the
# cloudfront_app module owns both the records and the redirect.
# The ALB is IPv4-only here (alb_https ip_address_type default, dedicated or
# shared), so A only.
# ---------------------------------------------------------------------------
resource "aws_route53_record" "alb_additional" {
  for_each = !var.enable_cloudfront && local.dns_points_to_aws ? toset(var.additional_domain_names) : toset([])

  zone_id = local.hosted_zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = local.alb_dns_name
    zone_id                = local.alb_zone_id
    evaluate_target_health = false
  }
}

# On a shared ALB every rule number must be unique across projects, so the
# redirect takes listener_rule_priority + 1 (its host-header set never overlaps
# the web rule's, so the relative order does not matter). Same formula on a
# dedicated ALB to keep one convention.
resource "aws_lb_listener_rule" "redirect_to_primary" {
  count = !var.enable_cloudfront && length(var.additional_domain_names) > 0 ? 1 : 0

  listener_arn = local.https_listener_arn
  priority     = var.listener_rule_priority + 1

  action {
    type = "redirect"
    redirect {
      host        = var.domain_name
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  condition {
    host_header {
      values = var.additional_domain_names
    }
  }

  tags = { Name = "${local.name}-redirect-to-primary" }
}
