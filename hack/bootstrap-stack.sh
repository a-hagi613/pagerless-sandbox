#!/usr/bin/env bash
# Deploys the showcase platform into a cluster that already exists and is
# reachable, whichever platform it runs on.
#
# `make up` creates a kind cluster and then calls this script; `make cloud-up`
# creates an EKS cluster and then calls the same script. Everything below the
# cluster is therefore identical on both, which is what keeps the local and
# cloud paths from drifting.
#
# The caller sets the context (PAGERLESS_KUBE_CONTEXT for EKS, otherwise the
# kind context). SANDBOX_URL, GITHUB_READ_TOKEN and GITHUB_WRITE_TOKEN come from
# .env, which `make configure` writes.
set -euo pipefail

# shellcheck source=hack/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_versions
load_env

# The platform charts and the demo Workloads live in this repository unless the
# showcase runs against a fork, so the platform revision follows SANDBOX_URL.
PLATFORM_REPO_URL="${PLATFORM_REPO_URL:-$SANDBOX_URL}"
PLATFORM_REVISION="${PLATFORM_REVISION:-main}"
KUBE_CONTEXT="${PAGERLESS_KUBE_CONTEXT:-kind-${KIND_CLUSTER_NAME}}"

require_commands helm kubectl openssl
require_env SANDBOX_URL GITHUB_READ_TOKEN GITHUB_WRITE_TOKEN

# Argo CD is the control plane of the showcase, not of the product: the product
# installs with `helm install` and knows nothing about it.
helm repo add argo "$ARGOCD_CHART_REPO" --force-update >/dev/null
helm upgrade --install argocd argo/argo-cd \
	--version "$ARGOCD_CHART_VERSION" \
	--namespace argocd --create-namespace \
	--values "$REPO_ROOT/platform/argocd/values.yaml" \
	--kube-context "$KUBE_CONTEXT" \
	--wait --timeout 15m

# Argo CD resolves an OCI Helm chart through a registered repository with
# enableOCI, so the Application can name the chart instead of a registry path.
kc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: pagerless-charts
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  name: pagerless
  url: ${PAGERLESS_CHART_REPO}
  enableOCI: "true"
EOF

# Argo CD reads the Sandbox repository with the read-scoped token, so a merged
# injection reaches the demo without the write token being available to it.
kc -n argocd create secret generic sandbox-repository \
	--from-literal=type=git \
	--from-literal=url="$SANDBOX_URL" \
	--from-literal=username=pagerless \
	--from-file=password=<(printf '%s' "$GITHUB_READ_TOKEN") \
	--dry-run=client -o yaml |
	kc label --local -f - argocd.argoproj.io/secret-type=repository -o yaml |
	kc apply -f -

# The release namespace exists before the chart syncs, because the Secrets below
# are mounted by the first rollout.
kc create namespace pagerless --dry-run=client -o yaml | kc apply -f -
kc create namespace monitoring --dry-run=client -o yaml | kc apply -f -

# The two fine-grained tokens of ADR-0015. They reach kubectl through file
# descriptors, not argv.
kc -n pagerless create secret generic github-read \
	--from-file=token=<(printf '%s' "$GITHUB_READ_TOKEN") \
	--dry-run=client -o yaml | kc apply -f -
kc -n pagerless create secret generic github-write \
	--from-file=token=<(printf '%s' "$GITHUB_WRITE_TOKEN") \
	--dry-run=client -o yaml | kc apply -f -

# Alertmanager sends opted-in alerts to the receiver with one bearer token. The
# receiver reads it from the pagerless namespace and Alertmanager mounts the
# same Secret from its own, so both copies are written from one generated value
# and an existing token is reused rather than rotated on every bootstrap.
alert_token="$(kc -n pagerless get secret pagerless-alertmanager \
	-o jsonpath='{.data.token}' 2>/dev/null | base64 --decode || true)"
[ -n "$alert_token" ] || alert_token="$(openssl rand -hex 32)"
for namespace in pagerless monitoring; do
	kc -n "$namespace" create secret generic pagerless-alertmanager \
		--from-file=token=<(printf '%s' "$alert_token") \
		--dry-run=client -o yaml | kc apply -f -
done
unset alert_token

# The root Application renders every child Application from platform/apps and
# points the sandbox Application at this repository's workloads/ directory.
helm template pagerless-root "$REPO_ROOT/platform/root" \
	--namespace argocd \
	--set "platform.repoURL=$PLATFORM_REPO_URL" \
	--set "platform.targetRevision=$PLATFORM_REVISION" \
	--set "sandbox.repoURL=$SANDBOX_URL" |
	kc apply -f -

# The timeouts are generous because a cloud session pulls its images for the
# first time; a kind run finishes well inside them.
wait_for_application root "" 600 synced
wait_for_application sandbox "" 1200
for app in chaos-mesh kube-prometheus-stack loki tempo opentelemetry-collector \
	observability-alerts observability-monitors observability-dashboards; do
	wait_for_application "$app" "" 1800
done
kc -n sandbox rollout status deployment/checkout --timeout=900s

# The pagerless Application is waited on for sync only. The chart pinned in
# platform/apps is the published 1.0.0, whose server also expects the Keycloak
# provider and the executor this repository deliberately does not run; Slice 11
# pins 2.0.0, which drops both. Its sync is what proves the registry, the values
# file and the destination are right.
wait_for_application pagerless "" 900 synced

# Approval is bound to the identity that runs the bootstrap, so the approval
# screen has an approver without a bundled identity provider (ADR-0020). It runs
# after the chart sync, because the chart creates the Role it binds. The binding
# name is derived from the identity, so a second run updates one binding.
approver="$(kc auth whoami -o jsonpath='{.status.userInfo.username}')"
case "$approver" in
"" | system:anonymous | system:serviceaccount:* | system:node:*)
	die "Approval bootstrap needs an explicit user identity, not ${approver:-an empty identity}."
	;;
esac
binding="pagerless-approver-$(printf '%s' "$approver" | sha256sum | cut -c1-16)"
kc -n pagerless create rolebinding "$binding" \
	--role=pagerless-approver \
	--user="$approver" \
	--dry-run=client -o yaml | kc apply -f -

cat <<EOF

The platform is synced. The demo Workloads are in the sandbox namespace and the
observability stack is in monitoring.

Open Grafana:
  kubectl --context ${KUBE_CONTEXT} -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

Inject a failure with: make break SCENARIO=oom
Restore the Sandbox with: make reset
EOF
