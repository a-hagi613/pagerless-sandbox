#!/usr/bin/env bash
# Destroys one EKS session and proves that nothing billable remains.
#
# Resources are outside Terraform's state and would survive a `terraform
# destroy` while still billing or blocking it: the EC2 instances Karpenter
# launched, the EBS volumes the CSI driver provisioned, the leftover `instant`
# fleets, and the detached `aws-K8S-*` network interfaces a terminated Spot node
# leaves behind. The instances and volumes are removed first, by deleting the
# NodePools and the claims and waiting for each to finish; the volumes, fleets,
# and interfaces are then swept by tag, which also covers a cluster that is
# already gone.
#
# The Terraform state bucket and the two GitHub Actions roles are the only
# resources this command leaves behind, by design: the bucket outlives every
# session, and the nightly teardown depends on the roles.
set -euo pipefail

# shellcheck source=hack/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_versions
load_env

CLOUD_ACCOUNT_ID="${PAGERLESS_CLOUD_ACCOUNT_ID:-207567775100}"
CLOUD_REGION="${AWS_REGION:-us-east-1}"
CLOUD_CLUSTER="${PAGERLESS_CLOUD_CLUSTER:-pagerless}"
CLOUD_CONTEXT="${PAGERLESS_CLOUD_CONTEXT:-pagerless-eks}"

# Every helper call below goes through kc() in hack/lib.sh, which reads
# PAGERLESS_KUBE_CONTEXT and otherwise falls back to the local kind cluster. A
# teardown that did not export it stopped Argo CD and then failed before
# destroying anything, while the session kept billing. Export the context this
# script computed, exactly as `make cloud-up` does, so the whole script targets
# the cluster the check above proves exists.
export PAGERLESS_KUBE_CONTEXT="$CLOUD_CONTEXT"

export AWS_REGION="$CLOUD_REGION"

require_commands terraform aws kubectl

account="$(aws sts get-caller-identity --query Account --output text)"
[ "$account" = "$CLOUD_ACCOUNT_ID" ] ||
	die "this teardown must run in account ${CLOUD_ACCOUNT_ID}, but the credentials are for ${account}."

# The kubeconfig entry is named after the cluster's ARN, so compute it before
# the state is destroyed and the outputs are gone.
cluster_arn="arn:aws:eks:${CLOUD_REGION}:${CLOUD_ACCOUNT_ID}:cluster/${CLOUD_CLUSTER}"

# 1. Remove what Terraform cannot see. Each step tolerates an absent cluster,
# because a failed session may already have lost its control plane and the
# destroy below must still run.
if kubectl --context "$CLOUD_CONTEXT" get nodes >/dev/null 2>&1; then
	echo "Stopping Argo CD before removing anything it manages."

	# The Applications sync with automated prune and selfHeal, so a namespace or
	# claim deleted while they exist is recreated within seconds. Delete the root
	# Application first, with a foreground cascade, which removes the child
	# Applications it manages, then any that remain, and refuse to continue until
	# none is left: everything below assumes nothing will reconcile.
	kc -n argocd delete application root --cascade=foreground --ignore-not-found --wait=true --timeout=10m >/dev/null 2>&1 || true
	kc -n argocd get applications -o name 2>/dev/null | while IFS= read -r application; do
		[ -n "$application" ] || continue
		kc -n argocd delete "$application" --cascade=foreground --ignore-not-found --wait=false >/dev/null 2>&1 || true
	done
	for _ in $(seq 1 60); do
		[ -z "$(kc -n argocd get applications -o name 2>/dev/null)" ] && break
		sleep 5
	done
	if [ -n "$(kc -n argocd get applications -o name 2>/dev/null)" ]; then
		die "Argo CD still has Applications; they would recreate what this teardown deletes. Delete them, then retry."
	fi

	echo "Removing the Karpenter capacity and the persistent claims before the destroy."

	# Deleting the NodePool stops new provisioning; deleting the NodeClaims drains
	# and terminates the instances. Karpenter's finalizer returns only after the
	# instance is gone.
	kubectl --context "$CLOUD_CONTEXT" delete nodepool --all --ignore-not-found >/dev/null 2>&1 || true
	kubectl --context "$CLOUD_CONTEXT" delete nodeclaims --all --ignore-not-found --wait=true --timeout=20m || true

	# Delete every workload namespace before the claims. A claim whose pod still
	# exists keeps its protection finalizer, so deleting claims first would block
	# and then orphan its volume when the timeout expired.
	for namespace in $(kc get namespaces -o name); do
		case "$namespace" in
		namespace/default | namespace/kube-* | namespace/argocd) continue ;;
		esac
		kc delete "$namespace" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	done
	for _ in $(seq 1 40); do
		kc get namespaces -o name | grep -Eq 'namespace/(sandbox|pagerless|monitoring|chaos-mesh)$' || break
		sleep 15
	done

	# A claim that survives the namespace must not survive the session: an EBS
	# volume is billed per GiB-month and is invisible to Terraform's state.
	pvc_deadline=$((SECONDS + 600))
	while [ -n "$(kc get pvc --all-namespaces -o name 2>/dev/null)" ]; do
		if [ "$SECONDS" -ge "$pvc_deadline" ]; then
			# A stuck protection finalizer would otherwise leave the volume behind.
			# The namespace is already gone, so no pod can still be using it.
			kc get pvc --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' |
				while IFS= read -r entry; do
					[ -n "$entry" ] || continue
					kc -n "${entry%%/*}" patch "pvc/${entry#*/}" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
				done
			kc get pv -o name | while IFS= read -r volume; do
				kc patch "$volume" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
			done
			pvc_deadline=$((SECONDS + 300))
		fi
		sleep 15
	done
	if [ -n "$(kc get pv -o name 2>/dev/null)" ]; then
		die "persistent volumes remain; destroying now could orphan an EBS volume. Inspect kubectl get pv and retry."
	fi
fi

# 1b. Karpenter's own resources: the `instant` EC2 fleet it launches capacity
# with and the IAM instance profile it creates per node launch. Neither is in
# Terraform's state, so a destroy leaves both behind — a live teardown had to
# remove exactly that pair by hand. The sweep runs before the volume sweep so a
# fleet that still holds instances terminates them first, which releases the
# volumes the sweep is about to look for.
bash "$REPO_ROOT/hack/cloud-karpenter-sweep.sh"

# 2. Sweep the volumes directly. The CSI driver deletes a volume asynchronously
# when its claim is deleted, and a destroy that gets there first orphans it. The
# sweep needs no cluster: it finds the volumes by tag, so it also runs when the
# control plane was lost before this command.
bash "$REPO_ROOT/hack/cloud-volume-sweep.sh"

# 2b. Delete the detached network interfaces a terminated Spot node leaves
# behind. They are not in Terraform's state either: an available `aws-K8S-*`
# interface keeps a security-group reference that blocks the VPC destroy. The
# query runs without a cluster, so it also covers a session whose control plane
# was lost.
echo "Removing leftover detached network interfaces."

eni_ids="$(
	{
		aws ec2 describe-network-interfaces --region "$CLOUD_REGION" \
			--filters "Name=status,Values=available" \
			--query "NetworkInterfaces[?starts_with(Description, 'aws-K8S-')].NetworkInterfaceId" \
			--output text 2>/dev/null || true
		aws ec2 describe-network-interfaces --region "$CLOUD_REGION" \
			--filters "Name=status,Values=available" "Name=tag:project,Values=pagerless" \
			--query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true
	} | tr -d '\r' | tr '\t' '\n' | awk 'NF' | sort -u
)"
for eni in $eni_ids; do
	echo "Deleting the detached network interface ${eni}."
	if ! aws ec2 delete-network-interface --region "$CLOUD_REGION" \
		--network-interface-id "$eni" >/dev/null 2>&1; then
		echo "warning: the network interface ${eni} could not be deleted; the teardown check will report it." >&2
	fi
done
# AWS deletes an interface asynchronously and the VPC cannot be destroyed while
# one still exists, so wait for the deletions to finish before the destroy.
remaining=""
for _ in $(seq 1 30); do
	remaining=""
	for eni in $eni_ids; do
		if aws ec2 describe-network-interfaces --region "$CLOUD_REGION" \
			--network-interface-ids "$eni" >/dev/null 2>&1; then
			remaining="${remaining} ${eni}"
		fi
	done
	if [ -z "$remaining" ]; then
		break
	fi
	sleep 5
done
if [ -n "$remaining" ]; then
	echo "warning: these network interfaces are still deleting:${remaining}" >&2
fi

# 3. Destroy the stack. An empty state is success: this is also what the nightly
# teardown runs.
terraform -chdir="$REPO_ROOT/infra" init -input=false
terraform -chdir="$REPO_ROOT/infra" destroy -input=false -auto-approve

# 4. Remove the session's kubeconfig entries, so a later command cannot silently
# target a cluster that no longer exists.
kubectl config delete-context "$CLOUD_CONTEXT" >/dev/null 2>&1 || true
kubectl config unset "clusters.${cluster_arn}" >/dev/null 2>&1 || true
kubectl config unset "users.${cluster_arn}" >/dev/null 2>&1 || true

# 5. Prove that nothing billable remains. The check retries for a bounded time,
# because AWS deletes asynchronously.
bash "$REPO_ROOT/hack/cloud-teardown-check.sh"

echo
echo "The EKS session is destroyed and the teardown check passed."
echo "The state bucket and the two GitHub Actions roles remain, as designed."
