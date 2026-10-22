# tflint configuration shared by every root and module in this tree.
# Run: tflint --init && tflint --recursive --config "$(pwd)/.tflint.hcl"
# (the Makefile `lint` target does exactly that).

config {
  # Follow `module "x" { source = "../../modules/x" }` references so local
  # modules are linted together with the root that calls them.
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# AWS ruleset: validates instance classes, engine versions, ARN shapes, etc.
# without touching the API (deep_check = false; true needs AWS credentials).
plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"

  deep_check = false
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}
