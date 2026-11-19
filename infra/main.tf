# The network is the whole of this configuration's free foundation (ADR-0009).
# The cluster, its compute and its identities are added by the tickets that need
# them, so that a pull request touching this directory can be checked with a
# read-only plan before any billable resource exists.
module "network" {
  source = "./modules/network"

  name                    = var.cluster_name
  cidr_block              = var.vpc_cidr
  availability_zone_count = var.availability_zone_count
}
