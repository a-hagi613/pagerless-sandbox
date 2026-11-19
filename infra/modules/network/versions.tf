# The module states the Terraform and provider floors it needs. The root module
# pins the exact versions (infra/versions.tf); these constraints only prevent the
# module being used by something too old.
terraform {
  # Native S3 lockfile locking, configured by the root module's backend.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.73.0"
    }
  }
}
