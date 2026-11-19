# Pinned exactly, like every other tool in this repository. Terraform 1.17.2 is
# the newest release (https://checkpoint-api.hashicorp.com/v1/check/terraform).
# The S3 backend's native lockfile locking needs Terraform 1.10.0 or newer
# (https://developer.hashicorp.com/terraform/language/backend/s3).
terraform {
  required_version = "= 1.17.2"

  required_providers {
    # Newest release of the AWS provider (https://registry.terraform.io/v1/providers/hashicorp/aws).
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.73.0"
    }
  }
}
