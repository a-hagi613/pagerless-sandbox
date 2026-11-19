# Documentation

The guides for running the showcase. Everything here describes this repository;
the product's own guides — installation, the CLI, the portal — live in
[`a-hagi613/pagerless`](https://github.com/a-hagi613/pagerless).

| Guide | What it covers |
| --- | --- |
| [EKS walkthrough](eks-walkthrough.md) | Starting a session, inspecting a node over Session Manager, injecting a Scenario, reaching Grafana, and tearing the session down. |
| [Scenarios](scenarios.md) | The ten failure injections: what each one changes, what it breaks, and where the evidence for it comes from. |
| [Cost](cost.md) | Reading what a session cost, and proving that a teardown left nothing behind. |
| [`../platform/observability/README.md`](../platform/observability/README.md) | The alert rules, the dashboards, the monitors, and the span and log pipelines behind them. |
| [`../infra/README.md`](../infra/README.md) | The Terraform: network, cluster, Karpenter, storage, and the two keyless CI roles. |
| [Decisions](adr/README.md) | The architecture records that constrain all of the above. |
