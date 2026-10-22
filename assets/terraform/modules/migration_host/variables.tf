variable "name" {
  description = "Base name, e.g. \"acme-prod\". Resources become \"<name>-migration-host\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "vpc_id" {
  description = "VPC for the instance's security group."
  type        = string
}

variable "subnet_id" {
  description = "Subnet to launch in. A PRIVATE subnet needs the network root's NAT gateway (SSM, dnf and the source database are all outbound); a PUBLIC subnet with assign_public_ip = true needs no NAT."
  type        = string
}

variable "assign_public_ip" {
  description = "Give the instance a public IP (only meaningful in a public subnet). Nothing listens on it: the security group has no inbound rules and SSH is not installed with a key. It is purely for outbound reach without a NAT gateway."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "Instance type. t4g.nano (2 vCPU burst, 0.5 GiB, ~$3/month) is enough to drive pg_dump | pg_restore for databases up to a few GB; t4g.small (~$12/month) for parallel restores (-j 4) of larger ones. Graviton (t4g) types need architecture = arm64."
  type        = string
  default     = "t4g.nano"

  validation {
    condition     = can(regex("^[a-z0-9]+\\.[a-z0-9]+$", var.instance_type))
    error_message = "instance_type must look like \"t4g.nano\"."
  }
}

variable "architecture" {
  description = "CPU architecture of the AMI: arm64 for t4g/m7g/c7g types, x86_64 for t3/m7i. Must match instance_type."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "pg_major" {
  description = "PostgreSQL client major version to install (pg_dump, pg_restore, psql). Must equal the TARGET RDS major; pg_dump from a newer client can read an older source. The root defaults it to the major of db_engine_version."
  type        = number
  default     = 18

  validation {
    condition     = var.pg_major >= 12 && var.pg_major <= 30
    error_message = "pg_major must be a PostgreSQL major version number such as 16, 17 or 18."
  }
}

variable "install_docker" {
  description = "Also install Docker so `docker run --rm postgres:<pg_major>` is available as the fallback client when the PGDG RPM for this major is not yet published for Amazon Linux 2023 (see README)."
  type        = bool
  default     = true
}

variable "root_volume_gib" {
  description = "Root gp3 volume size. 20 GiB holds a compressed dump of a database up to ~40 GB; raise it for bigger dumps or volume staging."
  type        = number
  default     = 20

  validation {
    condition     = var.root_volume_gib >= 8 && var.root_volume_gib <= 16384
    error_message = "root_volume_gib must be between 8 and 16384."
  }
}

variable "staging_bucket_arn" {
  description = "Optional S3 bucket ARN the host may read and write (dump files, volume contents). null = no S3 access."
  type        = string
  default     = null

  validation {
    condition     = var.staging_bucket_arn == null || can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9.-]+$", var.staging_bucket_arn))
    error_message = "staging_bucket_arn must be a bucket ARN like arn:aws:s3:::my-bucket (no trailing /*)."
  }
}

variable "staging_prefix" {
  description = "Key prefix inside staging_bucket_arn the host is limited to, e.g. \"migration/\". Empty string = the whole bucket."
  type        = string
  default     = ""
}

variable "readable_secret_arns" {
  description = "Secrets Manager secret ARNs the host may read (typically the RDS master secret and the app secret) so DATABASE_URL can be assembled on the host without pasting passwords through a terminal."
  type        = list(string)
  default     = []
}

variable "port_forward_hosts" {
  description = "Hosts to render `aws ssm start-session` port-forward commands for in the outputs, e.g. { postgres = { host = \"<rds endpoint>\", port = 5432, local_port = 15432 } }. Documentation only; nothing is created from it."
  type = map(object({
    host       = string
    port       = number
    local_port = number
  }))
  default = {}
}

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key for the root volume. null uses the account's default EBS key."
  type        = string
  default     = null
}
