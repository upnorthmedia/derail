output "vpc_id" {
  description = "ID of the shared VPC. Project roots look it up by tag instead of reading this output, but it is handy for the console."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR of the VPC (useful when writing security-group rules by hand)."
  value       = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the two public subnets (Tier = public). ALBs and, in no-NAT mode, ECS tasks go here."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "IDs of the two private subnets (Tier = private). RDS always goes here; ECS tasks only if a NAT gateway exists."
  value       = module.vpc.private_subnets
}

output "nat_public_ips" {
  description = "Public IPs of the NAT gateway (empty list when enable_nat_gateway = false). Give these to third parties that allow-list your egress IP. With stable_nat_eip = true this is the separately allocated, prevent_destroy address."
  value       = local.stable_nat ? aws_eip.nat[*].public_ip : module.vpc.nat_public_ips
}

output "stable_nat_eip_allocation_ids" {
  description = "Allocation ids of the prevent_destroy NAT EIP(s) (empty unless stable_nat_eip = true)."
  value       = aws_eip.nat[*].allocation_id
}

output "availability_zones" {
  description = "The two AZs the subnets were placed in."
  value       = local.azs
}

output "s3_endpoint_id" {
  description = "ID of the free S3 gateway endpoint."
  value       = aws_vpc_endpoint.s3.id
}
