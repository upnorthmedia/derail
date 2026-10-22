terraform {
  required_version = ">= 1.11, < 2.0"

  # Modules declare a floor, not a pin; the root's "~> 6.70" decides the
  # actual version. No provider or backend block here: roots own those.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28"
    }
  }
}
