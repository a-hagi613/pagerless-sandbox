# The keyless CI identity (spec #33, ADR-0009).
#
# This root is applied once by the operator, like the state bucket, and is never
# part of a session: `terraform destroy` on infra/ must not delete the roles the
# nightly teardown itself uses.
terraform {
  required_version = "= 1.17.2"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.73.0"
    }
    # Reads GitHub's certificate chain so the provider's thumbprints are the
    # current ones rather than a copied constant.
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.4.2"
    }
  }
}
