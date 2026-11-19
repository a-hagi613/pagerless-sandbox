# ADR-0025: The agent reaches Bedrock through EKS Pod Identity

- **Status:** Accepted
- **Date:** 2026-11-17
- **Moved from:** the product repository's register. This record keeps the EKS-specific half of that decision; the product's admission policy is the other half.

## Context

The investigation agent calls Amazon Nova 2 Lite. In a session, a model credential in a Secret, a ConfigMap or Git would be a credential that outlives the demonstration and has to be rotated by hand, so the agent's identity is an IAM role reached through EKS Pod Identity instead.

Pod Identity supplies credentials by mutating the pod before it is admitted: Amazon EKS adds two environment variables and one projected volume, `eks-pod-identity-token`, whose single source is a service-account token with the audience `pods.eks.amazonaws.com`.

## Decision

- `infra_identity` is one IAM role per cluster, `${cluster_name}-agent-bedrock`, that may call `bedrock:InvokeModel` and `bedrock:Converse` only on the `us.amazon.nova-2-lite-v1:0` inference profile and on the Nova 2 Lite foundation model in the three Regions that profile routes to. The foundation-model resources are listed explicitly, so no other model can be invoked.
- The role is associated with the `pagerless` namespace's `pagerless-agent` service account, so `values/pagerless.yaml` sets `agent.provider: bedrock` and `agent.awsRegion: us-east-1` and stores no key. No `eks.amazonaws.com/role-arn` annotation is needed, which is why `agent.serviceAccount.annotations` stays empty.
- The chart that installs the product must admit the volume the control plane injects. The pod is mutated before admission, so a policy that enumerates volumes exhaustively refuses every agent Job until it admits `eks-pod-identity-token` by name and shape.

## Consequences

- The token the agent receives is audience-scoped: the Kubernetes API server rejects it, and the EKS Auth API accepts it only for the role associated with that service account. The Job still receives no Kubernetes API token.
- A cluster without the association still schedules agent Jobs; the Bedrock call fails with the SDK's credential error rather than falling back to something else.
- The association is part of the session, so it is destroyed with the cluster. Nothing about the identity has to be rotated, and nothing about it is exported to a developer machine.
- An operator who installs the product on a cluster without Pod Identity can annotate the service account instead (IRSA), which is why the chart keeps `agent.serviceAccount.annotations`.
