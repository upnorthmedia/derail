# State for the shared network lives in the bucket created by ../bootstrap.
# Terraform does not allow variables in this block, so edit the two marked
# values by hand (get them with `terraform -chdir=../bootstrap output`).
# Nothing here is secret; commit this file.

terraform {
  backend "s3" {
    bucket = "tfstate-123456789012-us-east-1" # <- bootstrap output: state_bucket
    key    = "network/terraform.tfstate"      # keep as is; one shared network per account
    region = "us-east-1"                      # <- bootstrap output: aws_region

    use_lockfile = true # native S3 locking, no DynamoDB table
    encrypt      = true

    # Only if bootstrap was applied with state_kms_key_arn:
    # kms_key_id = "arn:aws:kms:us-east-1:123456789012:key/..."
  }
}
