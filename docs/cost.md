# Cost

A session spends money only while the EKS cluster exists: the demo, the platform
and the Workloads are manifests, and everything the session creates is destroyed
with it. This page covers the two questions a session leaves open: what it cost,
and whether it left anything behind.

## What a session cost

`hack/session-cost.sh` reads Cost Explorer for one date range. Run it by hand,
after the day has settled: Cost Explorer lags up to about 24 hours and bills USD
0.01 per request, so the script makes exactly one.

```bash
export AWS_PROFILE=pagerless
bash hack/session-cost.sh --start 2026-11-18
```

The default method filters on the `project=pagerless` cost-allocation tag, which
is the figure to quote. The tag is activated as a cost-allocation tag by hand and
can take a day to start reporting; `--method service` groups the same dates by
service instead, with no tag filter, which is accurate enough to state the
session's cost when the account's other spending is negligible — say so when you
use it.

## Proving the teardown left nothing behind

`make cloud-down` ends with `hack/cloud-teardown-check.sh`, and the nightly
teardown runs the same script after its `terraform destroy`. It fails, rather
than passing quietly, when an AWS query fails: an account that cannot be read is
not an empty account, and reading an error as "nothing left" is how a volume
escapes a teardown.

It looks in two places, because one of them lags:

- the Resource Groups Tagging API, for everything tagged `project=pagerless`;
- the EC2 API directly for EBS volumes, both the tagged ones and the ones the
  CSI driver created.

A tag-index entry whose resource EC2 reports gone is ignored; a resource EC2
still reports alive is a failure, and the check names it. Four kinds of resource
are expected to survive and are exempt:

| Resource | Why it survives |
| --- | --- |
| `pagerless-terraform-state-207567775100` | The state bucket outlives every session; destroying it would lose the state the next session needs. |
| `pagerless-github-plan`, `pagerless-github-destroy` | The two keyless CI roles, which the nightly teardown itself runs as. |
| The GitHub OIDC provider | Trusted by both roles; deleting it would break them. |
| A cluster KMS key waiting for its deletion window | It bills USD 1 per month until the window closes, which the check reports instead of hiding. |

## What the check cannot see

- A resource created outside the tagged path and without the CSI driver's tag.
  The teardown creates nothing that way, so this is a reviewer's concern rather
  than a gap in the script.
- Spend from a previous day, or from another tool in the account. The account has
  a hard cap for that ([ADR-0024](adr/0024-budget-guardrail-stays-outside-terraform.md)),
  and the cap is deliberately not managed by this repository.

## Why the teardown order matters

Deleting the namespaces and claims, sweeping the volumes, and only then
destroying the stack is not cosmetic: an EBS volume is billed per GiB-month and
is invisible to Terraform's state, so a destroy that runs first orphans it.
`hack/cloud-down-order-check.sh` fails a pull request that reorders those steps,
and the two `*-test.sh` scripts prove that the check and the sweep still treat a
live volume as a leftover.
