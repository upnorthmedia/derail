# alb_https: an internet-facing Application Load Balancer that terminates TLS
# with a free ACM certificate and does nothing else until services attach
# listener rules (see the ecs_service module). HTTP is redirected to HTTPS;
# a request matching no rule gets a plain 404.
#
# Cost (us-east-1, Oct 2026): $0.0225/h = ~$16.43/mo fixed + $0.008 per LCU-hour
# (a small app uses a fraction of an LCU, $1-5/mo) + one public IPv4 per AZ
# (2 x $3.65 = $7.30/mo). Realistic total ~$25-28/mo. This is the single
# largest fixed cost of a small deployment; sharing one ALB across projects
# with host-header rules is how you amortise it.

# ---------------------------------------------------------------------------
# Certificate (free) with DNS validation in Route 53
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = var.additional_domain_names
  validation_method         = "DNS"

  tags = { Name = "${var.name}-alb" }

  # ACM renews automatically as long as the validation CNAMEs stay in place.
  # A renewed/replaced certificate must exist before the old one is removed
  # from the listener, hence create_before_destroy.
  lifecycle {
    create_before_destroy = true
  }
}

# One validation CNAME per domain name. The for_each keys come from the input
# variables (known at plan time); only the record details are apply-time
# values from ACM. An apex and its wildcard share the same record;
# allow_overwrite keeps the duplicate from failing.
resource "aws_route53_record" "validation" {
  for_each = toset(concat([var.domain_name], var.additional_domain_names))

  zone_id         = var.hosted_zone_id
  name            = local.validation_options[each.key].resource_record_name
  type            = local.validation_options[each.key].resource_record_type
  ttl             = 60
  records         = [local.validation_options[each.key].resource_record_value]
  allow_overwrite = true
}

locals {
  validation_options = { for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => dvo }
}

# Blocks until ACM reports ISSUED (usually 2-5 minutes). Use its
# certificate_arn downstream so the listener never references a pending cert.
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

# ---------------------------------------------------------------------------
# Security group: the world may reach 80/443; the ALB may reach anything
# (its outbound is further restricted by the TARGET security groups, which only
# accept the container port from this SG).
# ---------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name        = "${var.name}-alb"
  description = "ALB ${var.name}: HTTP/HTTPS from the internet"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "http_ipv4" {
  security_group_id = aws_security_group.this.id
  description       = "HTTP from anywhere (redirected to HTTPS)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "http_ipv6" {
  security_group_id = aws_security_group.this.id
  description       = "HTTP from anywhere (redirected to HTTPS)"
  cidr_ipv6         = "::/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https_ipv4" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https_ipv6" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS from anywhere"
  cidr_ipv6         = "::/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all_ipv4" {
  security_group_id = aws_security_group.this.id
  description       = "To targets and health checks"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all_ipv6" {
  security_group_id = aws_security_group.this.id
  description       = "To targets and health checks"
  cidr_ipv6         = "::/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# The load balancer
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = var.internal
  ip_address_type    = var.ip_address_type
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.this.id]

  idle_timeout               = var.idle_timeout
  enable_http2               = true
  enable_deletion_protection = var.enable_deletion_protection
  # Drop requests with malformed header names instead of forwarding them;
  # this is the ALB-side mitigation for request smuggling.
  drop_invalid_header_fields = true
  desync_mitigation_mode     = "defensive"

  # Access logs: off by default (an extra bucket to manage). They cost only S3
  # storage and are the fastest way to answer "who sent that 502".
  dynamic "access_logs" {
    for_each = var.access_logs_bucket == null ? [] : [var.access_logs_bucket]
    content {
      enabled = true
      bucket  = access_logs.value
      prefix  = var.name
    }
  }

  # Name is the discovery key for project roots that share this ALB
  # (data "aws_lb" by tag); var.tags lets the platform root add Shared = "true".
  tags = merge({ Name = "${var.name}-alb" }, var.tags)
}

# Port 80 exists only to send browsers to HTTPS.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = { Name = "${var.name}-http" }
}

# Port 443: TLS 1.2+/1.3 only. Services attach aws_lb_listener_rule resources
# (host-header -> target group). With no matching rule the ALB answers 404,
# which is also what a random IP scanner hitting the bare DNS name sees.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "no rule matched"
      status_code  = "404"
    }
  }

  tags = { Name = "${var.name}-https" }
}

# ---------------------------------------------------------------------------
# DNS: alias records are free (no per-query charge for aliases to ALBs).
# ---------------------------------------------------------------------------

resource "aws_route53_record" "a" {
  count = var.create_dns_record ? 1 : 0

  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# AAAA only makes sense when the ALB actually has IPv6 addresses.
resource "aws_route53_record" "aaaa" {
  count = var.create_dns_record && var.ip_address_type == "dualstack" ? 1 : 0

  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "AAAA"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
