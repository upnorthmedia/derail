terraform {
  # 1.11 is the floor because the S3 backend's native lockfile (use_lockfile)
  # and write-only arguments both need it. "< 2.0" keeps a future major from
  # being picked up silently. OpenTofu >= 1.11 satisfies the same constraint.
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Every taggable resource created by this root gets these four tags. They are
  # the keys that bootstrap activates as cost-allocation tags, so "cost per
  # project" works in Cost Explorer without anyone remembering to tag things.
  default_tags {
    tags = local.tags
  }
}
