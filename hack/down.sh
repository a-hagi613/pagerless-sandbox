#!/usr/bin/env bash
# Deletes the local cluster and the Helm repository entry that make up created.
# The .env file is kept, because it holds the values the user entered.
set -euo pipefail

# shellcheck source=hack/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_versions

if kind get clusters | grep -qx "$KIND_CLUSTER_NAME"; then
	kind delete cluster --name "$KIND_CLUSTER_NAME"
else
	echo "No kind cluster named $KIND_CLUSTER_NAME exists."
fi

if command -v helm >/dev/null 2>&1 && helm repo list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx argo; then
	helm repo remove argo >/dev/null
fi

echo "Deleted the local stack. .env was kept; delete it to enter the values again."
