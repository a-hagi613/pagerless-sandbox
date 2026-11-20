#!/usr/bin/env bash
# Validates every Kubernetes manifest in this repository the way CI does, with
# the pinned kubeconform and Helm.
#
# Three kinds of manifest exist, and each is checked where it is readable:
#
#   - workloads/ holds plain objects and is validated strictly;
#   - platform/ mixes Helm chart templates, values files, Grafana dashboard
#     documents, and plain objects, so the plain objects are validated in place
#     and the two charts are rendered first;
#   - scenarios/ holds diffs, so each patch is proved applicable instead of
#     parsed.
#
# `make check` and .github/workflows/kubeconform.yml run this script, so a check
# that passes locally cannot fail in CI for a different reason.
set -euo pipefail

# shellcheck source=hack/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_versions

require_commands kubeconform helm git

if [ "$(kubeconform -v 2>/dev/null | sed 's/^v//')" != "${KUBECONFORM_VERSION#v}" ]; then
	die "kubeconform ${KUBECONFORM_VERSION} is required; this is $(kubeconform -v 2>/dev/null || echo none)."
fi

status=0
validate() {
	kubeconform -strict -summary -kubernetes-version 1.37.0 "$@" || status=1
}

# The rendered demo manifests. Every object here is a core Kubernetes kind.
echo "Validating workloads/."
validate "$REPO_ROOT/workloads"

# The plain objects of the platform. The Karpenter kinds, the Prometheus
# Operator kinds and the OTLP receiver's ExternalName Service are checked for
# syntax and structure, and skipped by schema where no schema exists.
echo "Validating the platform's plain manifests."
validate -ignore-missing-schemas \
	"$REPO_ROOT/platform/observability/alerts" \
	"$REPO_ROOT/platform/observability/monitors" \
	"$REPO_ROOT/platform/observability/otlp-receiver" \
	"$REPO_ROOT/platform/cloud/karpenter" \
	"$REPO_ROOT/platform/cloud/storage" \
	"$REPO_ROOT/platform/model-gateway"

# The two charts are Go templates until Helm renders them. The values they are
# rendered with are placeholders: rendering proves the templates and the
# Application shapes, not the repository the showcase will point at.
echo "Validating the rendered platform charts."
for chart in root apps; do
	helm template "pagerless-$chart" "$REPO_ROOT/platform/$chart" \
		--namespace argocd \
		--set "platform.repoURL=https://github.com/a-hagi613/pagerless-sandbox" \
		--set "platform.targetRevision=main" \
		--set "sandbox.repoURL=https://github.com/a-hagi613/pagerless-sandbox" \
		--set "sandbox.targetRevision=main" |
		kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.37.0 || status=1
done

# The child Applications are Argo CD kinds, so no Kubernetes schema covers them.
# What matters is which Applications exist and where Pagerless comes from, which
# is the contract between this repository and the product's released chart.
echo "Checking the platform's Application inventory."
rendered_apps="$(helm template pagerless-apps "$REPO_ROOT/platform/apps" \
	--namespace argocd \
	--set "platform.repoURL=https://github.com/a-hagi613/pagerless-sandbox" \
	--set "platform.targetRevision=main" \
	--set "sandbox.repoURL=https://github.com/a-hagi613/pagerless-sandbox" \
	--set "sandbox.targetRevision=main")"
for forbidden in pagerless-server pagerless-executor agentgateway gateway-api-crds mcp; do
	if printf '%s\n' "$rendered_apps" | grep -qE "^  name: ${forbidden}\$"; then
		echo "error: platform/apps renders a ${forbidden} Application, which the product no longer ships." >&2
		status=1
	fi
done
if ! printf '%s\n' "$rendered_apps" | grep -q 'repoURL: ghcr.io/a-hagi613/charts'; then
	echo "error: platform/apps no longer sources the product's OCI chart." >&2
	status=1
fi
if ! printf '%s\n' "$rendered_apps" | grep -qE "^ *targetRevision: ${PAGERLESS_CHART_VERSION}\$"; then
	echo "error: the pagerless Application is not pinned to chart ${PAGERLESS_CHART_VERSION}." >&2
	status=1
fi

# The CPU-stress experiment is the one Scenario object that is not a diff.
echo "Validating the CPU-stress experiment."
validate -ignore-missing-schemas "$REPO_ROOT/scenarios/cpu/stresschaos.yaml"

# A patch that no longer applies turns `make break` into a silent no-op, so each
# one is proved against the Target it changes. The patches are proved against a
# clean export of the base branch, never against this checkout: a Scenario branch
# already carries its own patch, and applying the others to it fails on the line
# numbers that patch moved, which says nothing about whether they are stale.
echo "Checking every Scenario patch against a clean base of workloads/."
base_ref="${PAGERLESS_BASE_REF:-origin/main}"
if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "$base_ref" >/dev/null; then
	git -C "$REPO_ROOT" fetch --quiet --depth=50 origin "${base_ref#origin/}" || true
fi
if base_commit="$(git -C "$REPO_ROOT" merge-base "$base_ref" HEAD 2>/dev/null)"; then
	patch_root="$(mktemp -d)"
	trap 'rm -rf "$patch_root"' EXIT
	git -C "$REPO_ROOT" archive "$base_commit" workloads | tar -x -C "$patch_root"
	for patch in "$REPO_ROOT"/scenarios/*/inject.patch; do
		if patch --silent --dry-run --forward -p1 -d "$patch_root" <"$patch" >/dev/null 2>&1; then
			echo "  applies: ${patch#"$REPO_ROOT"/}"
		else
			echo "error: $patch does not apply to workloads/ at ${base_commit:0:7}." >&2
			status=1
		fi
	done
else
	echo "warning: no $base_ref to compare against; checking the working tree instead." >&2
	for patch in "$REPO_ROOT"/scenarios/*/inject.patch; do
		if git -C "$REPO_ROOT" apply --check "$patch"; then
			echo "  applies: ${patch#"$REPO_ROOT"/}"
		elif git -C "$REPO_ROOT" apply --reverse --check "$patch"; then
			echo "  already applied: ${patch#"$REPO_ROOT"/}"
		else
			echo "error: $patch does not apply to workloads/." >&2
			status=1
		fi
	done
fi

if [ "$status" -ne 0 ]; then
	echo "Manifest validation failed." >&2
	exit 1
fi
echo "Every manifest is valid and every Scenario patch applies."
