# The model gateway

The showcase's agent speaks the OpenAI protocol and nothing else. Amazon Bedrock
speaks SigV4 and, for Nova, the Converse API. `platform/model-gateway` is the one
sandbox component that bridges the two, so a session can use the model the
product's own [ADR-0023](https://github.com/a-hagi613/pagerless/blob/main/docs/adr/0023-bedrock-uses-amazon-nova-2-lite.md)
chose without storing a credential anywhere.

It is a sandbox component, not a product one. The chart, the Portal, the CLI and
the `Page` CRD know nothing about it, and any OpenAI-compatible endpoint is an
equally valid value for `AI_BASE_URL`.

## What runs

The `model-gateway` Application renders [`platform/model-gateway`](../platform/model-gateway)
into the `pagerless` namespace:

| Object | Purpose |
| --- | --- |
| Deployment `model-gateway` | One LiteLLM pod, pinned to `ghcr.io/berriai/litellm:main-v1.34.4` (digest `sha256:8430b5d7ced85ef63d5a86a9d903acee231e333a3432bf8bfd77b57018b7ff6b`). |
| Service `model-gateway` | `ClusterIP` on port 4000. No Ingress, no LoadBalancer, nothing published. |
| ConfigMap `model-gateway` | The LiteLLM `model_list`: alias `bedrock/us.amazon.nova-2-lite-v1:0`, transport `bedrock/converse/us.amazon.nova-2-lite-v1:0`, `aws_region_name: us-east-1`. |
| ServiceAccount `model-gateway` | The name Pod Identity matches. It is bound to no Role, so it has no cluster permission. |

The alias is the value the agent sends as `AI_MODEL`. The transport is
`bedrock/converse/` rather than plain `bedrock/` because Nova 2 Lite does not
support Bedrock structured outputs: the agent asks for a forced tool call and the
Converse API is what carries OpenAI tool calls to the model.

There is no `master_key` and no LiteLLM API key. The Service is cluster-internal
and the agent holds no second credential; a key in the ConfigMap would be
readable by every pod in the namespace and would protect nothing.

## The identity

[`infra/model_gateway.tf`](../infra/model_gateway.tf) creates one role,
`pagerless-model-gateway`, and one EKS Pod Identity association for
`pagerless/model-gateway`. The role trusts `pods.eks.amazonaws.com` only from this
account and this cluster, and its policy allows:

- `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` on
  `us.amazon.nova-2-lite-v1:0` and its `us.` cross-Region inference profile;
- `bedrock:ListFoundationModels`, which takes no resource and is read-only.

That is the whole grant. There is no access key, no `AmazonBedrockFullAccess`, and
no `bedrock:*`. The Pod Identity agent add-on is already installed by
[`infra/eks.tf`](../infra/eks.tf), so this is the same keyless mechanism the EBS
CSI driver and the Karpenter controller use; no fallback IAM user exists, because
the cluster has the plumbing. The role is destroyed with the rest of the stack:
its name carries the `pagerless-` prefix that the teardown role's IAM statements
are scoped to.

## The request path

```
agent Job (namespace pagerless, no RBAC)
  → POST http://model-gateway.pagerless.svc.cluster.local:4000/v1/chat/completions
    → LiteLLM signs Bedrock Converse with the Pod Identity credentials
      → bedrock-runtime.us-east-1.amazonaws.com (Nova 2 Lite, us. profile)
```

**One caveat worth knowing.** The Pagerless chart ships a NetworkPolicy,
`pagerless-agent-egress`, that lets an agent pod reach only
`pagerless-server:8080`, DNS, and TCP **443** anywhere. A gateway on port 4000 is
outside that policy. The sandbox's VPC CNI add-on sets no configuration values, so
its network-policy agent is not enabled and the policy is not enforced in this
cluster — which is why port 4000 works today. If a future session enables network
policy enforcement, the agent's egress to this Service is denied, and the fix is a
chart-side egress rule for port 4000 (or a Service on 443 in front of the
gateway). This is recorded here rather than papered over with a policy that cannot
override the chart's deny-by-default egress.

## Proving it answers

Run this after `make cloud-up` returns and before injecting a Scenario:

```bash
kubectl --context pagerless-eks -n pagerless rollout status deployment/model-gateway --timeout=300s
kubectl --context pagerless-eks -n pagerless get svc model-gateway
kubectl --context pagerless-eks -n pagerless port-forward svc/model-gateway 4000:4000
```

In a second terminal, the OpenAI surface the agent uses:

```bash
curl -sS http://localhost:4000/v1/models | jq -r '.data[].id'
# bedrock/us.amazon.nova-2-lite-v1:0

curl -sS http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"bedrock/us.amazon.nova-2-lite-v1:0","messages":[{"role":"user","content":"Reply with the single word OK."}],"max_tokens":16}' |
  jq -r '.choices[0].message.content'
# OK
```

From inside the cluster, which is the hop the agent actually makes:

```bash
kubectl --context pagerless-eks -n pagerless run gateway-probe --rm -it --restart=Never \
  --image=curlimages/curl -- \
  curl -sS http://model-gateway.pagerless.svc.cluster.local:4000/v1/models
```

The gateway's own view of its credentials and model, without printing a
credential:

```bash
kubectl --context pagerless-eks -n pagerless logs deploy/model-gateway --tail=50
aws --profile pagerless bedrock list-foundation-models --region us-east-1 \
  --query "modelSummaries[?modelId=='amazon.nova-2-lite-v1:0'].[modelId,modelLifecycle.status]"
```

The second command runs as `pagerless-admin`, not as the gateway; it confirms the
model is ACTIVE in the Region before you blame the pod. To prove the gateway's
role is the narrow one, ask IAM:

```bash
aws --profile pagerless iam get-role --role-name pagerless-model-gateway \
  --query 'Role.AssumeRolePolicyDocument'
aws --profile pagerless iam list-role-policies --role-name pagerless-model-gateway
```

## Cost

Model tokens are the one part of a session that is not a fixed hourly rate: Nova
2 Lite bills per input and output token, and every Page spends some. The session
stays bounded because it is short and the demo's investigations are small, but
two things are worth knowing:

- The account's hard cap ([ADR-0024](adr/0024-budget-guardrail-stays-outside-terraform.md))
  attaches its deny policy to the IAM user `pagerless-admin`, not to this role, so
  it does **not** refuse the gateway's `bedrock:InvokeModel` calls when the budget
  fires. The budget still reports the spend; the cap is a guardrail on the
  operator's own identity.
- Deleting the stack deletes the role, so a session that ends takes its permission
  to spend with it.

## What can fail on a first run

- The pod starts but every call returns `AccessDeniedException` if the Pod
  Identity association was not applied (it is created by `terraform apply`, so
  this means the apply was skipped or failed) or if the service account name or
  namespace drifted from `pagerless/model-gateway`.
- `ModelNotReadyException` or `ThrottlingException` from Bedrock is the model or
  the account quota, not the gateway; check `list-foundation-models` above and the
  Bedrock quota for Nova 2 Lite in `us-east-1`.
- The image pull needs outbound HTTPS from the node, which the session already
  needs for every other image.
