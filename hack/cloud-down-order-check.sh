#!/usr/bin/env bash
# Fails when hack/cloud-down.sh stops enforcing the order that keeps a teardown
# from orphaning an EBS volume.
#
# The order is not cosmetic:
#
#   1. stop Argo CD, or self-heal recreates a namespace or claim seconds later;
#   2. delete the workload namespaces, so no pod holds a claim's finalizer;
#   3. delete the claims and wait, so the CSI driver starts deleting their volumes;
#   4. sweep the volumes directly, because the driver deletes asynchronously and
#      a destroy that gets there first orphans one;
#   5. destroy the stack, because the instances and volumes are not in its state.
#
# `make cloud-check` runs this, so a later edit that reorders the script fails a
# check instead of failing a paid session.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cloud-down.sh"

position() {
	local line
	line="$(grep -n -- "$1" "$script" | head -n 1 | cut -d: -f1 || true)"
	if [ -z "$line" ]; then
		echo "error: cloud-down.sh no longer contains: $1" >&2
		exit 1
	fi
	printf '%s\n' "$line"
}

stop_argocd="$(position 'delete application root')"
delete_namespaces="$(position 'kc delete "$namespace"')"
delete_claims="$(position 'kc get pvc --all-namespaces -o name')"
sweep_volumes="$(position 'cloud-volume-sweep.sh')"
destroy="$(position 'terraform -chdir="$REPO_ROOT/infra" destroy')"

if [ "$stop_argocd" -ge "$delete_namespaces" ] ||
	[ "$delete_namespaces" -ge "$delete_claims" ] ||
	[ "$delete_claims" -ge "$sweep_volumes" ] ||
	[ "$sweep_volumes" -ge "$destroy" ]; then
	echo "error: cloud-down.sh must stop Argo CD ($stop_argocd), delete the namespaces ($delete_namespaces)," >&2
	echo "       delete the claims ($delete_claims), sweep the volumes ($sweep_volumes)," >&2
	echo "       and only then destroy ($destroy), in that order." >&2
	exit 1
fi

echo "The teardown order is intact: Argo CD, namespaces, claims, volume sweep, destroy."
