# Optional AWS WAF web ACL attached to the distribution.
#
# A web ACL for CloudFront must have scope = "CLOUDFRONT" and live in us-east-1,
# so the resource overrides the provider region (provider v6 feature).
#
# Cost (pay-as-you-go, us-east-1, Oct 2026): $5.00/month per web ACL, $1.00/month
# per rule (a managed rule group counts as one), $0.60 per million requests
# inspected. This ACL = 1 web ACL + 4 rules = about $9/month + requests (+ $1
# per path_rate_limits entry). The
# CloudFront flat-rate plans include a quota of rules instead (5 on Free, 25 on
# Pro) and *require* a web ACL on the distribution.
#
# Rule order matters: lower priority numbers evaluate first. The rate limit goes
# first so an abusive IP is cut off before the (more expensive) managed groups run.

locals {
  # Index-keyed so the rule set is stable at plan time; a missing name becomes a
  # slug of the prefix ("/api/auth/" -> "api-auth").
  path_rate_limits = {
    for i, r in var.path_rate_limits : i => {
      name        = coalesce(r.name, trim(replace(lower(r.path_prefix), "/[^a-z0-9]+/", "-"), "-"))
      path_prefix = r.path_prefix
      limit       = r.limit
    }
  }
}

resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0

  region      = "us-east-1"
  name        = "${var.name}-cloudfront"
  description = "Managed rules + rate limit for ${var.domain_name}"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # 1. Rate limit per source IP over a 5-minute window. Replaces Vercel's
  #    Attack Challenge Mode; 2000 req/5 min is ~7 req/s sustained per IP.
  rule {
    name     = "rate-limit-per-ip"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # 1b. Per-path rate limits (e.g. /api/auth/ at 300 req / 5 min per IP, the
  #     login brute-force case the global limit is too loose for). They
  #     evaluate after the global limit and before the managed groups.
  #     Priorities 1..9 are reserved for them; more than 9 entries would
  #     collide with the IP reputation rule at 10, hence the validation.
  dynamic "rule" {
    for_each = local.path_rate_limits
    content {
      name     = "rate-limit-${rule.value.name}"
      priority = 1 + rule.key

      action {
        block {}
      }

      statement {
        rate_based_statement {
          limit                 = rule.value.limit
          aggregate_key_type    = "IP"
          evaluation_window_sec = 300

          scope_down_statement {
            byte_match_statement {
              positional_constraint = "STARTS_WITH"
              search_string         = rule.value.path_prefix

              field_to_match {
                uri_path {}
              }

              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-rate-limit-${rule.value.name}"
        sampled_requests_enabled   = true
      }
    }
  }

  # 2. Known-bad source IPs (Amazon threat intelligence). Cheap, low false-positive.
  rule {
    name     = "aws-ip-reputation"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # 3. OWASP-style core rule set. Two body-inspection rules are switched to
  #    COUNT because CMS admin saves (Payload rich text, large JSON) trip them;
  #    they still log matches so you can re-enable them once you know your traffic.
  rule {
    name     = "aws-common-rule-set"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        dynamic "rule_action_override" {
          for_each = toset(var.waf_count_only_rules)
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-common-rule-set"
      sampled_requests_enabled   = true
    }
  }

  # 4. Known bad inputs (Log4j JNDI, path traversal into known app files, etc.).
  rule {
    name     = "aws-known-bad-inputs"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${var.name}-cloudfront" }
}
