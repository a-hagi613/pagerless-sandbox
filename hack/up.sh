#!/usr/bin/env bash
# Creates the local stack: a kind cluster on a pinned node image, and then the
# shared bootstrap that `make cloud-up` runs on EKS too (hack/bootstrap-stack.sh).
set -euo pipefail

# shellcheck source=hack/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_versions

require_commands kind openssl
bash "$REPO_ROOT/hack/configure.sh"
load_env
require_env SANDBOX_URL GITHUB_READ_TOKEN GITHUB_WRITE_TOKEN

kind create cluster --name "$KIND_CLUSTER_NAME" --image "$KIND_NODE_IMAGE" --wait 180s

# kind inherits the host resolver, which on Docker Desktop and CI runners can be
# a local stub that does not answer external names from inside the cluster. Argo
# CD pulls Helm and OCI charts through CoreDNS, so forward to public resolvers.
if kc -n kube-system get configmap coredns >/dev/null 2>&1; then
	corefile="$(kc -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
	forwarded="$(printf '%s\n' "$corefile" | sed 's|^\( *\)forward \. /etc/resolv.conf$|\1forward . 8.8.8.8 1.1.1.1|')"
	if [ "$forwarded" != "$corefile" ]; then
		kc -n kube-system create configmap coredns --from-literal=Corefile="$forwarded" \
			--dry-run=client -o yaml | kc apply -f -
		kc -n kube-system rollout restart deployment/coredns
		kc -n kube-system rollout status deployment/coredns --timeout=120s
	fi
fi

bash "$REPO_ROOT/hack/bootstrap-stack.sh"

echo
echo "The local stack is up. Inject a failure with: make break SCENARIO=oom"
echo "Restore the Sandbox with: make reset"
echo "Delete the cluster with: make down"
