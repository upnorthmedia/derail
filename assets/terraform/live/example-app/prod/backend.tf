# Remote state. The bucket is created once per account by the bootstrap root
# (named tfstate-<account id>-<region>). Terraform cannot interpolate variables
# here, so the three values are literal; keep them in sync with
# terraform.tfvars (project/environment) when you copy this root.
terraform {
  backend "s3" {
    bucket       = "tfstate-123456789012-us-east-1"
    key          = "example-app/prod/terraform.tfstate" # <project>/<environment>/terraform.tfstate
    region       = "us-east-1"
    use_lockfile = true # native S3 lock object (<key>.tflock); no DynamoDB table
    encrypt      = true
    # kms_key_id = "arn:aws:kms:us-east-1:123456789012:key/..." # only if bootstrap set state_kms_key_arn
  }
}
