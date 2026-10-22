# Shared VPC from the network root, discovered by tag (no remote-state coupling),
# exactly as the project roots do it.
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

# The zone that holds the platform's own hostname (ACM validation CNAMEs and
# the alias record). It must already be delegated, or the certificate never
# issues and aws_acm_certificate_validation times out.
data "aws_route53_zone" "platform" {
  count = var.create_shared_alb ? 1 : 0

  name         = var.platform_hosted_zone_name
  private_zone = false
}
