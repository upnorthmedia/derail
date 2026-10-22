variable "platform_name" {
  type        = string
  description = "Prefix for the VPC and subnet names and the value of the Platform tag. Project roots find this VPC by the tag Name = \"<platform_name>-vpc\", so change it only if you also change the project roots' platform_name."
  default     = "platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}$", var.platform_name))
    error_message = "platform_name must be 2-23 chars, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "environment" {
  type        = string
  description = "Environment tag for the shared network. It is shared by all projects, so prod is the honest default."
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "repository" {
  type        = string
  description = "Git repository holding this code, e.g. github.com/acme/infra (Repository tag)."
}

variable "aws_region" {
  type        = string
  description = "Region to build the VPC in. Must match the region of the project roots that use it."
  default     = "us-east-1"
}

variable "vpc_cidr" {
  type        = string
  description = "Address range for the VPC. The default gives 65k addresses, split into four /20 subnets (two public, two private) with room for more."
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid IPv4 CIDR no smaller than /20 (four /24-or-larger subnets are carved out of it)."
  }
}

variable "enable_nat_gateway" {
  type        = bool
  description = <<-EOT
    Create a single NAT gateway so private subnets can reach the internet (pull images, call APIs).
    COST: about $33/month for the gateway hour charge plus $0.045 per GB processed, even when idle.
    Leave false and run ECS tasks in the public subnets with a public IP (the project roots'
    task_in_public_subnets = true) until you need private tasks.
  EOT
  default     = false
}

variable "enable_flow_logs" {
  type        = bool
  description = "Send VPC flow logs to CloudWatch Logs (30-day retention). Useful for debugging security groups; costs CloudWatch ingestion (~$0.50/GB) which is usually a few dollars a month for small apps. Off by default."
  default     = false
}

variable "stable_nat_eip" {
  type        = bool
  description = "Allocate the NAT gateway's Elastic IP as a separate prevent_destroy resource (aws_eip.nat) and hand it to the VPC module (reuse_nat_ips), so the egress address survives any NAT gateway rebuild. Turn on when third parties allow-list your outbound IP. Only used when enable_nat_gateway = true. Switching it on for an existing NAT gateway replaces the gateway (new IP once, then stable)."
  default     = false
}
