terraform {
  # OpenTofu >= 1.11 reads the same constraint; see the repo README.
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }

  # No provider alias for us-east-1: with provider v6 the cloudfront_app and
  # s3_media modules set `region = "us-east-1"` directly on the ACM/WAF resources.
}
