# The state bucket is created once by infra/bootstrap and persists between
# sessions (ADR-0009). Native lockfile locking replaces a DynamoDB table, so the
# session leaves no billable resource behind besides the bucket itself.
#
# `allowed_account_ids` refuses to read or write state in any other account, so a
# misconfigured shell cannot plan a destroy against a different environment.
terraform {
  backend "s3" {
    bucket              = "pagerless-terraform-state-207567775100"
    key                 = "phase-3/terraform.tfstate"
    region              = "us-east-1"
    encrypt             = true
    use_lockfile        = true
    allowed_account_ids = ["207567775100"]
  }
}
