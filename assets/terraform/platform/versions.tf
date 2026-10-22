terraform {
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

  # Project = <platform_name> ("platform" by default), so the shared pool shows
  # up in Cost Explorer as its own line, separate from every project's line.
  default_tags {
    tags = local.tags
  }
}
