# ADR-0025: The agent reaches Bedrock through EKS Pod Identity

- **Status:** Superseded by the v2 agent credential model
- **Date:** 2026-11-17
- **Superseded:** 2026-11-19
- **Moved from:** the product repository's register. This record keeps the EKS-specific half of that decision; the product's admission policy is the other half.

## Context

Pagerless v1's investigation agent called Amazon Nova 2 Lite through an IAM role
reached with EKS Pod Identity, so no model credential lived in a Secret, a
ConfigMap or Git. Pod Identity supplied credentials by mutating the pod before
it was admitted: Amazon EKS added two environment variables and one projected
volume, `eks-pod-identity-token`, whose single source was a service-account token
with the audience `pods.eks.amazonaws.com`.

## Decision (v1, superseded)

- `infra_identity` was one IAM role per cluster, `${cluster_name}-agent-bedrock`,
  that could call `bedrock:InvokeModel` and `bedrock:Converse` only on the
  `us.amazon.nova-2-lite-v1:0` inference profile and on the Nova 2 Lite
  foundation model in the three Regions that profile routes to.
- The role was associated with the `pagerless` namespace's `pagerless-agent`
  service account, so `values/pagerless.yaml` set `agent.provider: bedrock` and
  `agent.awsRegion: us-east-1` and stored no key.
- The product's admission policy admitted the volume the control plane injected.

## Why it was superseded

Pagerless v2 removes both halves of the mechanism. There is no Bedrock provider:
any OpenAI-compatible endpoint is configured by base URL, key and model. The
agent is a per-Page Job with **zero** Kubernetes RBAC and **no** cloud identity;
the model key, the GitHub write token and the Target Repository are supplied by
the server from the `pagerless-credentials` Secret and mounted into the Job by
name. There is no Pod Identity association for the agent to admit, and the
sandbox no longer creates the IAM role.

## Consequences

- `infra/agent_identity.tf`, the two Bedrock variables and the `agent_role_arn`
  output are gone. The session creates no IAM role for the agent and no
  `pods.eks.amazonaws.com` trust.
- A cluster without Pod Identity no longer changes how the agent authenticates;
  the model endpoint is an ordinary HTTPS endpoint reached through the internet
  gateway, or a local endpoint the operator supplies.
- Removing an IAM role from Terraform does not delete it on an existing
  deployment by itself if it was created outside state; an operator upgrading an
  old session should destroy that session rather than migrate it, which is what
  `make cloud-down` does.
