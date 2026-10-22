# Shared network: one VPC per account that every project root plugs into.
# This is the only place we use a community module instead of plain
# resources, because a correct VPC is ~30 resources (subnets, route tables,
# associations, IGW, optional NAT/EIP, flow logs) and the
# terraform-aws-modules/vpc module is the de-facto standard for it.
#
# Project roots do NOT read this root's state. They discover the VPC and
# subnets by tags (Name = "<platform_name>-vpc", Tier = public|private), so
# the two roots stay decoupled.

data "aws_region" "current" {}

# Only AZs that are generally available to this account (excludes opt-in
# Local Zones / Wavelength zones that would surprise you with capacity and
# pricing differences).
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = "${var.platform_name}-${var.environment}"

  tags = {
    Project     = var.platform_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = var.repository
  }

  # Two AZs is the minimum an Application Load Balancer accepts and the
  # minimum RDS Multi-AZ needs. More AZs cost nothing by themselves but a
  # per-AZ NAT gateway would; we keep it at two.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Four equal subnets carved from the VPC range: index 0-1 public, 2-3
  # private. With the default /16 each subnet is a /20 (4k addresses), and
  # half the VPC range stays free for future subnets.
  public_subnets  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i + 2)]

  # Only allocate our own EIP when there is a NAT gateway to attach it to.
  stable_nat = var.enable_nat_gateway && var.stable_nat_eip
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  # The module names the VPC "<name>" and subnets "<name>-public-<az>", so
  # this is what the project roots' data "aws_vpc" filter matches.
  name = "${var.platform_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  # Tasks launched in public subnets get a public IP automatically, which is
  # how the "no NAT gateway" mode reaches ECR, Secrets Manager and the
  # internet. Public IPv4 addresses cost $0.005/hour each (~$3.60/month per
  # running task); still far cheaper than a NAT gateway for 1-5 tasks.
  map_public_ip_on_launch = true

  # Needed for RDS endpoints and VPC-endpoint private DNS to resolve.
  enable_dns_hostnames = true
  enable_dns_support   = true

  # NAT: see variables.tf for the cost discussion. single_nat_gateway puts
  # one gateway in the first public subnet and routes both private subnets
  # through it: cheapest option, at the price of one AZ being a dependency.
  enable_nat_gateway = var.enable_nat_gateway
  single_nat_gateway = true

  # Bring-your-own Elastic IP (stable_nat_eip): the module then attaches
  # aws_eip.nat below instead of allocating its own, so any change that
  # rebuilds the NAT gateway keeps the same egress address. Needed the moment
  # a third party (bank, payment provider, customer firewall) allow-lists it.
  reuse_nat_ips       = local.stable_nat
  external_nat_ip_ids = local.stable_nat ? aws_eip.nat[*].id : []

  # Flow logs to CloudWatch, created only when enabled. 60s aggregation makes
  # them useful for live debugging; 30-day retention caps the storage bill.
  enable_flow_log                                 = var.enable_flow_logs
  create_flow_log_cloudwatch_log_group            = var.enable_flow_logs
  create_flow_log_cloudwatch_iam_role             = var.enable_flow_logs
  flow_log_cloudwatch_log_group_name_prefix       = "/aws/vpc-flow-log/${local.name}/"
  flow_log_cloudwatch_log_group_retention_in_days = 30
  flow_log_max_aggregation_interval               = 60
  flow_log_traffic_type                           = "ALL"

  # Tier/Platform tags are the discovery contract for project roots.
  public_subnet_tags = {
    Tier     = "public"
    Platform = var.platform_name
  }

  private_subnet_tags = {
    Tier     = "private"
    Platform = var.platform_name
  }

  vpc_tags = {
    Platform = var.platform_name
  }
}

# S3 gateway endpoint: free, and it keeps S3 traffic (ECR image layers are
# stored in S3, so image pulls too) off the NAT gateway / public internet.
# Attached to every route table so both public and private subnets use it.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.public_route_table_ids, module.vpc.private_route_table_ids)

  tags = {
    Name = "${var.platform_name}-s3-endpoint"
  }
}

# Stable egress address for the NAT gateway (see reuse_nat_ips above). It is
# the address you hand to anyone who allow-lists your outbound traffic, so it
# is protected from accidental release: to let it go you must delete the
# lifecycle block on purpose. Unattached EIPs cost $3.65/month, attached ones
# are included in the NAT price.
resource "aws_eip" "nat" {
  count = local.stable_nat ? 1 : 0

  domain = "vpc"

  tags = {
    Name = "${var.platform_name}-nat-egress"
  }

  lifecycle {
    prevent_destroy = true
  }
}
