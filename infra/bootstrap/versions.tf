# The one-time state bootstrap is applied with local state, because the bucket it
# creates is what the stack's S3 backend stores its state in. It is applied once
# per account and never destroyed (see infra/README.md).
terraform {
  required_version = "= 1.17.2"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.73.0"
    }
  }
}
