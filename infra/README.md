# Cloud infrastructure

Terraform for the EKS environment that `make cloud-up` creates and `make cloud-down` destroys, in the showcase repository [`a-hagi613/pagerless-sandbox`](https://github.com/a-hagi613/pagerless-sandbox). The design decisions are [ADR-0009](../docs/adr/0009-eks-network-without-nat-or-load-balancers.md) (no NAT gateways or load balancers), [ADR-0010](../docs/adr/0010-cost-model.md) (near-zero cost), and [ADR-0024](../docs/adr/0024-budget-guardrail-stays-outside-terraform.md) (the budget guardrail stays outside Terraform).

## Layout

```
infra/
  bootstrap/       One-time S3 state bucket, applied with local state
  modules/network/ VPC, public subnets, internet gateway
  *.tf             The stack: providers, backend, network, cluster, Karpenter, identities
```

The stack is split so that a pull request adds one layer at a time: the network here, then the cluster and its compute, then the identity that lets it run the stack.

## The state bucket, once per account

The bucket persists between sessions. Only the cluster is destroyed.

```sh
cd infra/bootstrap
terraform init
terraform apply
```

The bucket is `pagerless-terraform-state-207567775100`, named in `variables.tf` and in `infra/backend.tf`; the two must match. It has versioning, SSE-S3, an ownership control that disables ACLs, a public access block, a lifecycle rule that expires superseded versions after 30 days, and a bucket policy that denies non-TLS access. `force_destroy` is off, so a `terraform destroy` refuses to remove it while it holds state.

## The stack

```sh
cd infra
terraform init
terraform plan
```

Both commands read the account; `plan` changes nothing. The stack refuses to run against any account other than `207567775100` (`allowed_account_ids` in `providers.tf`), and the backend applies the same guard to the state file.

Run it with the `pagerless` profile:

```sh
AWS_PROFILE=pagerless terraform plan
```

## Checks

CI (`.github/workflows/infra.yml`) runs these on every pull request that touches `infra/`, with Terraform 1.17.2, tflint 0.66.0 and the AWS ruleset 0.50.0 pinned, and with no AWS credentials:

```sh
cd infra
terraform fmt -check -recursive
(cd bootstrap && terraform init -backend=false && terraform validate)
terraform init -backend=false && terraform validate
tflint --init && tflint --recursive
```

`terraform init` writes `.terraform.lock.hcl`. The lock file is committed, so every run uses the same provider build.

## The cluster

The cluster is EKS 1.37, the newest version in standard support when it was written (verified with `aws eks describe-cluster-versions` on 2026-11-17, standard support to 2027-11-30). `terraform-aws-modules/eks` 21.30.2 is pinned, and it is the only module dependency besides `terraform-aws-modules/eks//modules/karpenter` at the same version, which also pins `terraform-aws-modules/kms` 4.0.0 behind it.

- **Compute.** One Spot managed node group, `t3.large`, one node, for Karpenter, CoreDNS and Argo CD. Karpenter provisions the rest from [`platform/cloud/karpenter`](../platform/cloud/karpenter): x86_64 Spot only, instance sizes from medium to xlarge, and a NodePool limit of 12 vCPU and 24 GiB.
- **Add-ons.** VPC CNI `v1.23.3-eksbuild.1`, CoreDNS `v1.14.7-eksbuild.35`, kube-proxy `v1.37.0-eksbuild.39` and the Pod Identity agent `v1.4.1-eksbuild.3`, read from `aws eks describe-addon-versions --kubernetes-version 1.37` on 2026-11-17. Nothing is left on `most_recent`.
- **Access.** `authentication_mode = "API"`, so access entries replace the `aws-auth` ConfigMap, and the identity that applies the configuration keeps cluster-admin. Both the system managed node group role and the Karpenter node role attach `arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore`, enabling zero-port-22 node shell access via AWS Systems Manager Session Manager without SSH keys or inbound security-group rules (see [docs/eks-walkthrough.md](../docs/eks-walkthrough.md)).
- **Identity.** The v2 server holds one strictly read-only cluster identity: `get`/`list`/`watch` on the resources a Page needs, `get` on pod logs, and `get` on `/openapi/v3`. It holds no write verb on any workload, and no `exec`, `attach` or `port-forward`. The agent is a per-Page Job with **no** cluster RBAC and no AWS identity; the server reads the model endpoint, the GitHub write token and the Target Repository from the `pagerless-credentials` Secret, and the agent receives only its model key by name ([ADR-0025](../docs/adr/0025-the-agent-job-admits-the-pod-identity-token.md), superseded).
- **No Auto Mode.** Karpenter, not EKS Auto Mode, owns the extra capacity (ADR-0010).
- **Storage.** The EBS CSI driver (`v1.68.0-eksbuild.1`) runs from a Pod Identity association, and [`platform/cloud/storage`](../platform/cloud/storage) creates a default gp3 StorageClass named `standard`, which is what the kind local-path class is called. Its volumes carry `project=pagerless`, and its reclaim policy is `Delete`, so a claim that goes away takes its volume with it. Dynamically provisioned volumes are not in this state, which is why `make cloud-down` deletes the claims, waits, and then sweeps the volumes by tag before it destroys the cluster. The teardown check also queries EBS directly, because the Resource Groups tagging index can lag, and it fails when an AWS query fails rather than reading that as an empty account.

Karpenter's controller, node role, Pod Identity association and Spot interruption queue all come from the `karpenter` submodule. The chart is installed by `make cloud-up`, which is also what applies the NodePool and EC2NodeClass.

## The CI identity, once per account

Pull request plans and the nightly teardown authenticate with a short-lived OIDC token instead of an AWS access key. That identity is account plumbing, not part of a session, so it lives in its own root and is applied once, like the state bucket:

```sh
cd infra/ci
terraform init
terraform apply
```

It creates the GitHub Actions OIDC provider (`https://token.actions.githubusercontent.com`) and two roles:

| Role | Assumed by | Permissions |
| --- | --- | --- |
| `pagerless-github-plan` | a `pull_request` workflow in `a-hagi613/pagerless-sandbox` | read the state bucket and describe the infrastructure; no writes |
| `pagerless-github-destroy` | a `main` branch workflow, which is the only place the nightly run executes | describe and delete for the stack's services, the state bucket it must write, and IAM writes scoped to `pagerless*` identities; no action that creates or starts anything |

Both trust policies match the repository's immutable subject claim, which includes the owner ID `92589940` and repository ID `1460616727` because the repository was created after 2026-07-15. A recycled repository name cannot inherit either role. Neither role can be assumed by a fork: the plan job also refuses a pull request whose head repository is not this one.

A `terraform destroy` of `infra/` never touches this root, so the nightly teardown cannot delete the roles it runs as.

The plan job plans with `-lock=false`, because the plan role may only read the state bucket; the nightly job takes the lock, because `destroy` writes state.

## Network posture

- Public subnets only, one per Availability Zone, each with a public IPv4 address on launch. Nodes reach Amazon ECR, the OpenAI-compatible model endpoint and the cluster endpoint through the internet gateway; there is no NAT gateway.
- No load balancer, no public ingress, and no endpoint other than the EKS API. The Portal and Grafana are reached with `kubectl port-forward`.
- Nothing in this layer accepts a connection: it creates no security group and no listener. The node security group arrives with the cluster, which permits traffic only from the cluster security group that Amazon EKS creates, never from a CIDR block or the internet. Node shell inspection uses outbound AWS Systems Manager Session Manager rather than SSH keys or inbound port-22 rules.

## Cost

Everything in this directory is free to create: a VPC, three subnets, an internet gateway and a route table incur no hourly charge. The first billable resource appears when the cluster is created, which is why the network is applied by `make cloud-up` rather than on its own.

Every resource carries `project=pagerless` through the provider's default tags. The tag is activated as a cost-allocation tag outside Terraform, so the tag value is what Cost Explorer reports per session. The value stays `pagerless` rather than becoming `pagerless-sandbox`: the state bucket, the two GitHub Actions roles and the teardown filter in [`hack/cloud-teardown-check.sh`](../hack/cloud-teardown-check.sh) are account plumbing the showcase inherited, and one tag value keeps a session's resources visible to the same check.

## The budget guardrail is not here

The `pagerless-hard-cap-5usd` budget, its automatic deny action and `PagerlessBudgetsActionRole` are managed by hand and must stay that way. See [ADR-0024](../docs/adr/0024-budget-guardrail-stays-outside-terraform.md). No `aws_budgets_*` resource belongs in this directory.
