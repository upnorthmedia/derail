data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

# GitHub OIDC provider created once per account by the bootstrap root. Looking
# it up (instead of building the ARN) fails fast with a clear error if
# bootstrap has not been applied yet.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# Shared VPC from the network root, discovered by tag (no remote-state coupling).
data "aws_vpc" "shared" {
  filter {
    name   = "tag:Name"
    values = ["${var.platform_name}-vpc"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }
  filter {
    name   = "tag:Tier"
    values = ["public"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }
  filter {
    name   = "tag:Tier"
    values = ["private"]
  }
}

# ---------------------------------------------------------------------------
# Shared platform resources (platform/ root), looked up only when the matching
# shared_* flag is on. Same idea as the VPC: discovery by name/tag, never by
# remote state, so this root cannot be broken by the platform root's state
# layout and cannot modify anything it did not create (the ingress rules and
# listener certificate/rules in shared.tf are separate resources).
# ---------------------------------------------------------------------------

data "aws_ecs_cluster" "shared" {
  count = var.shared_cluster ? 1 : 0

  cluster_name = var.platform_name
}

data "aws_lb" "shared" {
  count = var.shared_alb ? 1 : 0

  tags = {
    Name   = "${var.platform_name}-alb"
    Shared = "true"
  }

  # The alb_https module attaches exactly one security group, and the task
  # security groups accept traffic from "the ALB SG", so this root assumes
  # one. If somebody attached more by hand, fail here with a clear message
  # instead of silently picking one of them.
  lifecycle {
    postcondition {
      condition     = length(self.security_groups) == 1
      error_message = "The shared ALB ${self.arn} has ${length(self.security_groups)} security groups; this root expects exactly the one created by modules/alb_https."
    }
  }
}

data "aws_lb_listener" "shared_https" {
  count = var.shared_alb ? 1 : 0

  load_balancer_arn = data.aws_lb.shared[0].arn
  port              = 443
}

data "aws_db_instance" "shared" {
  count = var.shared_database ? 1 : 0

  # modules/rds_postgres names the instance "<name>-db"; the platform root
  # passes name = platform_name.
  db_instance_identifier = "${var.platform_name}-db"
}

data "aws_security_group" "shared_db" {
  count = var.shared_database ? 1 : 0

  vpc_id = data.aws_vpc.shared.id

  filter {
    name   = "tag:Name"
    values = ["${var.platform_name}-db"]
  }

  # Belt and braces: the SG found by tag must be the one attached to the
  # instance found by identifier, otherwise the ingress rules below would open
  # the wrong group.
  lifecycle {
    postcondition {
      condition     = contains(data.aws_db_instance.shared[0].vpc_security_groups, self.id)
      error_message = "Security group ${self.id} (tag Name=${var.platform_name}-db) is not attached to RDS instance ${var.platform_name}-db."
    }
  }
}

# Existing public zone (create_hosted_zone = false). When this root owns the
# zone the resource in dns.tf is used instead; local.hosted_zone_id hides the
# difference from every consumer.
data "aws_route53_zone" "this" {
  count = var.create_hosted_zone ? 0 : 1

  name         = var.hosted_zone_name
  private_zone = false
}
