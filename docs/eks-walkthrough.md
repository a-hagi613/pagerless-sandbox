# Interactive EKS session walkthrough

This guide covers a live session created by `make cloud-up`: opening a shell
inside a worker node over AWS Systems Manager Session Manager, injecting a
Scenario against the `pagerless-eks` context, reaching Grafana, and destroying
the session cleanly with `make cloud-down`.

For the Terraform layout, IAM roles and cost controls behind the cluster, see
[`infra/README.md`](../infra/README.md), [ADR-0009](adr/0009-eks-network-without-nat-or-load-balancers.md),
[ADR-0010](adr/0010-cost-model.md) and [ADR-0024](adr/0024-budget-guardrail-stays-outside-terraform.md).

## 1. Start or select the session

```bash
export AWS_PROFILE=pagerless
export AWS_REGION=us-east-1
export PAGERLESS_KUBE_CONTEXT=pagerless-eks
```

`make cloud-up` applies the Terraform, installs Karpenter, applies its NodePool,
EC2NodeClass and StorageClass, and then runs the same platform bootstrap the
local kind stack runs. When it returns, every Application the platform owns is
synced:

```bash
kubectl --context pagerless-eks get nodes -o wide
kubectl --context pagerless-eks -n argocd get applications
kubectl --context pagerless-eks -n sandbox get pods
```

## 2. Open a shell inside a node

Both the system node group role (`infra/eks.tf`) and the Karpenter node role
(`infra/karpenter.tf`) attach `arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore`.
The Amazon Linux 2023 EKS node AMI runs the SSM Agent out of the box and
registers over outbound HTTPS, so no SSH key pair and no inbound port-22
security-group rule exists.

```bash
INSTANCE_ID="$(kubectl --context pagerless-eks get nodes \
  -o jsonpath='{.items[0].spec.providerID}' | awk -F/ '{print $NF}')"
AWS_PROFILE=pagerless aws ssm start-session --target "$INSTANCE_ID" --region us-east-1
```

Inside the node shell:

```bash
sudo crictl ps
sudo journalctl -u kubelet -n 50 --no-pager
exit
```

## 3. Inject a Scenario

`make break` commits the injection through an auto-merging pull request, waits
for Argo CD to sync the merge, and then waits for the failure itself. It targets
whichever cluster `PAGERLESS_KUBE_CONTEXT` names:

```bash
export PAGERLESS_KUBE_CONTEXT=pagerless-eks
make break SCENARIO=oom
```

The [Scenario catalogue](scenarios.md) lists the ten injections, and
`make scenarios` prints their names. What happens next is the product's job: the
chart in `platform/apps` installs the v2 server, which opens a Page for the
failing Target, investigates it in an ephemeral agent Job, and records Findings,
a Diagnosis and a Proposal. Approve the Proposal in the embedded Portal or with
`kubectl page approve`; Pagerless then opens one pull request against
`workloads/`, and Verification closes the Page as `Recovered` or `NotRecovered`
after the merge.

The bootstrap prints the Portal's port-forward and the bootstrap-token command.
The terminal path is `kubectl page` (the Krew plugin is named `page`), configured
once with `kubectl page config set` and pointed at the same server.

## 4. Reach Grafana

Nothing in the platform is exposed to the internet, so Grafana is reached with a
port-forward:

```bash
kubectl --context pagerless-eks -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

To make it reachable from another device on a Tailscale tailnet (for example
`http://devbox:3000`), bind the forward on all interfaces:

```bash
kubectl --context pagerless-eks -n monitoring port-forward --address 0.0.0.0 svc/kube-prometheus-stack-grafana 3000:80
```

The Grafana administrator password is in the `kube-prometheus-stack-grafana`
Secret in the `monitoring` namespace:

```bash
kubectl --context pagerless-eks -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 --decode; echo
```

The **Pagerless Target metrics** and **Pagerless Target logs** dashboards
chart the demo; `ContainerOOMKilled`, `ServiceErrorRateHigh` and
`ContainerMemoryGrowth` are the rules that fire during a Scenario and opt the
alert in to a Page.

The Portal runs in `pagerless-server` and is reached the same way:

```bash
kubectl --context pagerless-eks -n pagerless port-forward svc/pagerless-server 8080:8080
kubectl --context pagerless-eks -n pagerless get secret pagerless-admin-secret \
  -o jsonpath='{.data.token}' | base64 --decode; echo
```

## 5. Clean teardown

```bash
export AWS_PROFILE=pagerless
export PAGERLESS_KUBE_CONTEXT=pagerless-eks
make reset
make cloud-down
```

`make cloud-down` stops Argo CD, deletes the Target namespaces and their
claims, sweeps the EBS volumes, removes the Karpenter fleets and detached network
interfaces, runs `terraform destroy`, deletes the `pagerless-eks` kubeconfig
context, and then proves with `hack/cloud-teardown-check.sh` that no billable
`project=pagerless` resource remains. [Cost](cost.md) explains what the check
does and does not exempt.
