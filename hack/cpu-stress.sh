#!/usr/bin/env bash
# Applies or removes Scenario 9, CPU stress. The Chaos Mesh experiment is a
# cluster object rather than a Sandbox commit, so it is applied outside Git
# (ADR-0019) and needs no repository credentials.
set -euo pipefail

# shellcheck source=hack/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_versions
load_env

action="${1:-}"
experiment="cpu-stress-payment"
manifest="$REPO_ROOT/scenarios/cpu/stresschaos.yaml"

require_commands kubectl

case "$action" in
apply)
	kc apply -f "$manifest"
	echo "Applied the CPU-stress experiment $experiment. Waiting for Chaos Mesh to inject it."
	deadline=$((SECONDS + 180))
	while :; do
		conditions="$(kc -n sandbox get stresschaos "$experiment" \
			-o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null || true)"
		records="$(kc -n sandbox get stresschaos "$experiment" \
			-o jsonpath='{.status.experiment.containerRecords[*].id}' 2>/dev/null || true)"
		if grep -qx 'AllInjected=True' <<<"$conditions" && [ -n "$records" ]; then
			break
		fi
		[ "$SECONDS" -lt "$deadline" ] ||
			die "Chaos Mesh did not inject $experiment within 3 minutes (conditions: ${conditions:-none})."
		sleep 3
	done

	echo "Chaos Mesh injected $experiment into:"
	for id in $records; do
		echo "  $id"
	done
	echo "The payment Workload is under CPU stress and its manifests are unchanged."
	echo "Start the Triage with: kubectl triage --context kind-${KIND_CLUSTER_NAME} --namespace sandbox deploy/payment"
	echo "Remove the experiment with: make reset"
	;;
clear)
	if ! kc get customresourcedefinition stresschaos.chaos-mesh.org >/dev/null 2>&1; then
		echo "Chaos Mesh is not installed, so there is no experiment to remove."
		exit 0
	fi
	kc -n sandbox delete stresschaos --all --ignore-not-found --wait=true
	echo "Removed every Chaos Mesh experiment from the sandbox namespace."
	;;
*)
	die "usage: hack/cpu-stress.sh apply|clear"
	;;
esac
