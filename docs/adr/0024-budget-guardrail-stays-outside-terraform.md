# ADR-0024: The budget guardrail stays outside Terraform

- **Status:** Accepted
- **Date:** 2026-11-17
- **Relates to:** [ADR-0009](0009-eks-network-without-nat-or-load-balancers.md), [ADR-0010](0010-cost-model.md)

## Context

The cloud environment is created and destroyed per session, so the account's last line of defence against a forgotten cluster is an AWS Budgets hard cap that blocks new spend. That cap protects against the exact failure Terraform could cause: a plan that leaves a billable resource running.

Terraform owns the cluster's lifecycle. If Terraform also owned the cap, a mistyped `terraform destroy -target`, a pruned resource, or a damaged state file could remove the guardrail together with the cluster. The cap is also an account-wide policy rather than part of the workload, and it existed before this configuration did.

The account holds three hand-managed pieces:

- Budget `pagerless-hard-cap-5usd`: USD 5.00 monthly, actual spend.
- Budget action `bd2b251e-edf4-41ab-9662-5eb9fa4d6b6b` on that budget: `APPLY_IAM_POLICY` at 100% of actual spend, approval model `AUTOMATIC`, attaching `arn:aws:iam::207567775100:policy/PagerlessBudgetDenyNewSpend` to the IAM user `pagerless-admin`.
- IAM role `arn:aws:iam::207567775100:role/PagerlessBudgetsActionRole`, the execution role of that action.

The deny policy refuses new spend: it denies `ec2:RunInstances`, `ec2:StartInstances`, `ec2:RequestSpotInstances`, `ec2:CreateFleet`, `ec2:CreateNatGateway`, `ec2:AllocateAddress`, `ec2:CreateVolume`, the Autoscaling create and scale actions, `eks:CreateCluster`, `eks:CreateNodegroup`, `eks:UpdateNodegroupConfig`, `eks:CreateFargateProfile`, `elasticloadbalancing:CreateLoadBalancer`, the RDS create actions, `bedrock:InvokeModel`, `bedrock:Converse` and their streaming forms, `lambda:CreateFunction`, and the SageMaker create actions. It does not deny deletion, so teardown still works after the cap fires.

## Decision

- The budget, its action, and `PagerlessBudgetsActionRole` remain unmanaged by Terraform and are never imported into it.
- `infra/` contains no `aws_budgets_budget`, `aws_budgets_budget_action`, or IAM resource for `PagerlessBudgetsActionRole`. A reviewer rejects a pull request that adds one.
- The guardrail is recreated by hand, from the values recorded above, if it is ever lost. It is not reproducible from the repository, deliberately.
- The account's other budget, `My Monthly Cost Budget` at USD 30.00, is pre-existing personal spending control and is likewise left alone.
- The repository keeps the guardrail verifiable by hand rather than by plan: before a paid session the operator confirms the budget, its action and the action's role with `aws budgets describe-budgets`, `aws budgets describe-budget-actions-for-account` and `aws iam get-role`.

## Consequences

- `terraform destroy` can never remove the cap, because Terraform never knew about it.
- A change to the cap does not appear in a Terraform plan. The three hand-managed objects are the one part of the cloud setup whose drift is checked by the operator, and ADR-0009's cost argument depends on them being correct.
- The cap is account-wide, not per-project: it stops all new spend in the account, including work unrelated to Pagerless. That is intended: it is the reason the cap is worth having.
- Because the cap denies creation rather than deletion, a session that fires the cap can still run `make cloud-down`.
