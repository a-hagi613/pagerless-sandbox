# Every resource in this configuration, and in the modules it calls, carries the
# cost-allocation tag through the provider's default tags (ADR-0010). The tag is
# activated as a cost-allocation tag by hand, outside Terraform, so a session
# cost can be read from Cost Explorer after the cluster is destroyed.
provider "aws" {
  region = var.aws_region

  # A plan or apply against any other account is refused before it can change
  # anything.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      project = "pagerless"
    }
  }
}
