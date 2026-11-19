# Documentation

The guides for running the showcase. Everything here describes this repository;
the product's own guides — installation, `kubectl page`, the Portal and the
credential contract — live in
[`a-hagi613/pagerless`](https://github.com/a-hagi613/pagerless).

The showcase runs the v2 flow end to end. A Scenario breaks a Target, the
observability rules opt an alert in with `pagerless.dev/watch: "true"`, or the
watcher sees a Kubernetes Event or status change. Either way Pagerless opens a
Page, investigates it in an ephemeral agent Job, and records Findings, a
Diagnosis and a Proposal. A human approves one Proposal hash in the Portal or
with `kubectl page approve`; Pagerless opens one pull request against the Target
Repository, and Verification ends the Page as `Recovered` or `NotRecovered`
after the merge. The product never writes to the cluster.

| Guide | What it covers |
| --- | --- |
| [EKS walkthrough](eks-walkthrough.md) | Starting a session, inspecting a node over Session Manager, injecting a Scenario, reaching Grafana and the Portal, and tearing the session down. |
| [Scenarios](scenarios.md) | The ten failure injections: what each one changes, what it breaks, and where the evidence for it comes from. |
| [Cost](cost.md) | Reading what a session cost, and proving that a teardown left nothing behind. |
| [`../platform/observability/README.md`](../platform/observability/README.md) | The alert rules, the dashboards, the monitors, and the span and log pipelines behind them. |
| [`../infra/README.md`](../infra/README.md) | The Terraform: network, cluster, Karpenter, storage, and the two keyless CI roles. |
| [Decisions](adr/README.md) | The architecture records that constrain all of the above. |
