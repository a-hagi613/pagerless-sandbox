# ADR-0010: An EKS session costs near zero, and the account has a hard cap

- **Status:** Accepted
- **Date:** 2026-11-16
- **Moved from:** the product repository's register. This record carries the cloud half of that decision; the model-cost clauses stayed with the product.

## Context

The showcase's only material cost is the EKS session it runs: everything else is committed YAML and a local kind cluster. A demonstration that can be left running by accident is a demonstration that eventually costs more than it is worth.

The account also holds a hand-managed AWS Budgets cap. It exists so that a forgotten resource stops the account rather than the invoice, and it is deliberately not a Terraform resource (see [ADR-0024](0024-budget-guardrail-stays-outside-terraform.md)).

## Decision

- **Everything free is created first.** `infra/main.tf` holds the network: a VPC, three public subnets, an internet gateway and a route table, none of which bills while they exist. The first billable resource appears when the cluster does, which is why `make cloud-up` applies both and `make cloud-check` validates both without an account.
- **Spot only.** The system node group is one Spot `t3.large`, and the Karpenter NodePool admits x86_64 Spot instances of instance categories `c`, `m` and `r`, generation 5 or later, limited to 12 vCPU and 24 GiB. On-demand would multiply the session cost for the same demo.
- **A session, not an environment.** `make cloud-up` creates the cluster and `make cloud-down` destroys it, with the volume sweep and the teardown check in between. A session must not span the nightly teardown at 03:17 UTC.
- **A backstop, not a schedule.** `.github/workflows/nightly-teardown.yml` destroys anything still standing, through a keyless OIDC role, and then runs the same zero-residue check an operator runs by hand.
- **One cost-allocation tag.** Every resource carries `project=pagerless`, so Cost Explorer reports the session and the teardown check finds what a teardown missed. `hack/session-cost.sh` reads that tag once, by hand, because Cost Explorer bills every request.

## Consequences

- A session that is never torn down costs a few dollars a day rather than a monthly run rate, and the nightly teardown bounds even that.
- The teardown is the load-bearing part of this decision, so it is tested without credentials: `hack/cloud-down-order-check.sh` fails a reordered teardown, and the two `*-test.sh` scripts fail a check that reads an AWS error as an empty account.
- The demo cannot be a permanently hosted service: it exists for the length of a session, and the recording is what outlives it.
