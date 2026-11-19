terraform {
  backend "s3" {
    bucket              = "pagerless-terraform-state-207567775100"
    key                 = "phase-3/ci.tfstate"
    region              = "us-east-1"
    encrypt             = true
    use_lockfile        = true
    allowed_account_ids = ["207567775100"]
  }
}
