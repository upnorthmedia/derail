# Glue for the shared platform (platform/ root). Nothing in this file exists
# unless shared_alb or shared_database is true, and everything here is a
# separate resource that only this project's state owns: a certificate and its
# attachment to the shared listener, and ingress rules on the shared database
# security group. Destroying this root removes exactly these and leaves the
# platform untouched.

# ---------------------------------------------------------------------------
# Shared ALB: the project's own certificate, served by SNI.
#
# The shared listener's default certificate covers only the platform's own
# hostname. Each project adds a certificate for its names with
# aws_lb_listener_certificate; the ALB picks the right one from the TLS SNI
# header. Up to 25 certificates per listener (hard quota), which also caps the
# number of projects per shared ALB.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "shared_alb" {
  count = var.shared_alb ? 1 : 0

  domain_name               = var.domain_name
  subject_alternative_names = local.alb_certificate_sans
  validation_method         = "DNS"

  tags = { Name = "${local.name}-alb" }

  # ACM renews automatically while the validation CNAMEs exist. A replaced
  # certificate must be attached before the old one is removed from the
  # listener, hence create_before_destroy.
  lifecycle {
    create_before_destroy = true
  }
}

# One validation CNAME per name, in this project's own zone (never the
# platform's). Keys come from variables, so they are known at plan time.
resource "aws_route53_record" "shared_alb_validation" {
  for_each = var.shared_alb ? toset(concat([var.domain_name], local.alb_certificate_sans)) : toset([])

  zone_id         = local.hosted_zone_id
  name            = local.shared_alb_validation_options[each.key].resource_record_name
  type            = local.shared_alb_validation_options[each.key].resource_record_type
  ttl             = 60
  records         = [local.shared_alb_validation_options[each.key].resource_record_value]
  allow_overwrite = true
}

locals {
  shared_alb_validation_options = var.shared_alb ? { for dvo in aws_acm_certificate.shared_alb[0].domain_validation_options : dvo.domain_name => dvo } : {}
}

# Blocks until ACM reports ISSUED (2-5 minutes once the zone is authoritative).
resource "aws_acm_certificate_validation" "shared_alb" {
  count = var.shared_alb ? 1 : 0

  certificate_arn         = aws_acm_certificate.shared_alb[0].arn
  validation_record_fqdns = [for r in aws_route53_record.shared_alb_validation : r.fqdn]
}

resource "aws_lb_listener_certificate" "shared_alb" {
  count = var.shared_alb ? 1 : 0

  listener_arn    = local.https_listener_arn
  certificate_arn = aws_acm_certificate_validation.shared_alb[0].certificate_arn
}

# ---------------------------------------------------------------------------
# Shared database: open 5432 on the platform instance's security group to this
# project's task security groups (web, worker, migration host). The rules
# live in this state; the SG itself belongs to the platform root.
#
# count, not for_each, for the same reason as in modules/rds_postgres: the task
# SG ids are created in this apply and unknown at plan time, and count only
# needs the list length. New entries go at the end of the list.
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "shared_db" {
  count = var.shared_database ? length(local.data_client_security_group_ids) : 0

  security_group_id            = data.aws_security_group.shared_db[0].id
  description                  = "PostgreSQL from ${local.name} security group ${count.index}"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = local.data_client_security_group_ids[count.index]

  tags = { Name = "${local.name}-shared-db-${count.index}" }
}
