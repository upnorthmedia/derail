provider "aws" {
  region = var.aws_region

  # Every taggable resource gets these four tags, which bootstrap activates as
  # cost-allocation tags. "Cost per project" is then Cost Explorer grouped by Project.
  default_tags {
    tags = local.tags
  }
}
