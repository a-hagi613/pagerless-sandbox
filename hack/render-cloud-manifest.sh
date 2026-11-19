#!/usr/bin/env bash
# Renders the two Karpenter manifests that name the cluster and its node role.
# `make cloud-up` and this script both use it, so a placeholder that stops
# matching is caught by `make cloud-check` rather than by a failed session.
set -euo pipefail

input="$1"
cluster="${2:?the cluster name is required}"
node_role="${3:?the Karpenter node role name is required}"

# The placeholders are distinctive so that a missing substitution is visible,
# and a rendered document contains none of them.
out="$(sed -e "s|__CLUSTER_NAME__|${cluster}|g" -e "s|__NODE_ROLE_NAME__|${node_role}|g" "$input")"
case "$out" in
*__CLUSTER_NAME__* | *__NODE_ROLE_NAME__*)
	echo "error: $input still contains a placeholder after rendering." >&2
	exit 1
	;;
esac
printf '%s\n' "$out"
