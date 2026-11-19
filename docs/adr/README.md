# Sandbox decisions

Architecture decisions that constrain the showcase: the EKS environment, the demo's rendering path, the cost model and its guardrail, and the identity the v2 agent no longer needs. Each record states what was decided and what follows from it.

The numbers are the ones these records had in the product's register, which they were moved from when the showcase split out. Keeping them means a reference in the product's history still resolves, and a reader comparing the two registers is not confused by two numbering schemes.

| Record | Decision | Status |
| --- | --- | --- |
| [ADR-0009](0009-eks-network-without-nat-or-load-balancers.md) | Public subnets, no NAT gateway, no load balancer | Accepted |
| [ADR-0010](0010-cost-model.md) | A session costs near zero, and the account has a hard cap | Accepted |
| [ADR-0019](0019-opentelemetry-demo-as-rendered-manifests.md) | The OpenTelemetry Demo is committed as rendered manifests | Accepted |
| [ADR-0024](0024-budget-guardrail-stays-outside-terraform.md) | The budget guardrail stays outside Terraform | Accepted |
| [ADR-0025](0025-the-agent-job-admits-the-pod-identity-token.md) | The agent reaches Bedrock through EKS Pod Identity | Superseded |

Decisions about the product itself — the chart, the CRDs, the CLI, the portal, the inference client — are recorded in the product repository, not here. When a decision spans both, the product's register holds the rule and this one holds what the showcase has to do to satisfy it.

A record is never deleted. A reversed decision is marked `Superseded` in place and links to the record that replaces it.
