variable "name" {
  description = "Base name, e.g. \"acme-prod\". The load balancer becomes \"<name>-alb\" (ALB names are capped at 32 characters)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,27}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, start with a letter, and be at most 28 characters so \"<name>-alb\" fits the 32-character ALB limit."
  }
}

variable "vpc_id" {
  description = "VPC for the ALB security group."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the ALB (at least two, in different AZs). Each AZ costs one public IPv4 address (~$3.65/mo)."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An Application Load Balancer needs at least two subnets in different Availability Zones."
  }
}

variable "domain_name" {
  description = "Primary hostname served over HTTPS, e.g. \"app.example.com\". Must live in the Route 53 zone given by hosted_zone_id."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a lowercase DNS name like app.example.com (no scheme, no trailing dot)."
  }
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID that contains domain_name (and additional_domain_names). Used for ACM DNS validation and the alias record."
  type        = string
}

variable "additional_domain_names" {
  description = "Extra hostnames to add to the certificate as Subject Alternative Names (e.g. \"www.example.com\" or \"*.example.com\"). They must be in the same hosted zone. No DNS records are created for them."
  type        = list(string)
  default     = []
}

variable "idle_timeout" {
  description = "Seconds the ALB keeps an idle connection open. Raise it (up to 4000) for long-polling or slow uploads; keep it above any keep-alive timeout in your app server."
  type        = number
  default     = 60

  validation {
    condition     = var.idle_timeout >= 1 && var.idle_timeout <= 4000
    error_message = "idle_timeout must be between 1 and 4000 seconds."
  }
}

variable "enable_deletion_protection" {
  description = "Refuse to delete the ALB through the API. Turn on in prod once DNS points at it."
  type        = bool
  default     = false
}

variable "access_logs_bucket" {
  description = "Optional S3 bucket name for ALB access logs (the bucket needs a policy allowing the regional ELB log-delivery account). null = no access logs. Logs cost only S3 storage."
  type        = string
  default     = null
}

variable "create_dns_record" {
  description = "Create the Route 53 alias record(s) for domain_name pointing at the ALB. Set false when CloudFront fronts the ALB and owns the DNS name."
  type        = bool
  default     = true
}

variable "internal" {
  description = "Create an internal (private-IP) ALB instead of an internet-facing one. Needs private subnets; rarely what a web app wants."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Extra tags for the load balancer itself (merged over Name). The platform root sets Shared = \"true\" so project roots can find a shared ALB with data \"aws_lb\" by tags."
  type        = map(string)
  default     = {}
}

variable "ip_address_type" {
  description = "\"ipv4\" or \"dualstack\". dualstack also serves IPv6 (and gets an AAAA record) but REQUIRES subnets with an IPv6 CIDR; the ALB creation fails otherwise."
  type        = string
  default     = "ipv4"

  validation {
    condition     = contains(["ipv4", "dualstack"], var.ip_address_type)
    error_message = "ip_address_type must be \"ipv4\" or \"dualstack\"."
  }
}
