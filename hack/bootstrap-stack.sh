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
# kind context). SANDBOX_URL, GITHUB_READ_TOKEN, GITHUB_WRITE_TOKEN and the AI
# endpoint come from .env, which `make configure` writes.
set -euo pipefail

# shellcheck source=hack/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_versions
load_env

# The platform charts and the demo Targets live in this repository unless the
# showcase runs against a fork, so the platform revision follows SANDBOX_URL.
PLATFORM_REPO_URL="${PLATFORM_REPO_URL:-$SANDBOX_URL}"
PLATFORM_REVISION="${PLATFORM_REVISION:-main}"
KUBE_CONTEXT="${PAGERLESS_KUBE_CONTEXT:-kind-${KIND_CLUSTER_NAME}}"

# kc() reads PAGERLESS_KUBE_CONTEXT, so export the one context this script
# computed instead of letting a direct caller (hack/up.sh, or an operator on a
# cloud session) fall back to a different cluster. On the kind path the value is
# the kind context, which is what the fallback would have produced anyway.
export PAGERLESS_KUBE_CONTEXT="$KUBE_CONTEXT"

require_commands helm kubectl openssl
require_env SANDBOX_URL GITHUB_READ_TOKEN GITHUB_WRITE_TOKEN AI_BASE_URL AI_MODEL
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

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

# The v2 credential contract: one Secret, one key per credential. The write
# token reaches kubectl through a file descriptor, never argv. GITHUB_REPO is the
# Target Repository, and GITHUB_TOKEN is the write-scoped token that carries an
# approved Proposal.
#
# ALERTMANAGER_WEBHOOK_TOKEN is the one key the alert receiver authenticates:
# v2 compares it in constant time for the Alertmanager dialect. Alertmanager
# mounts its own copy from the monitoring namespace, so both copies are written
# from one generated value and an existing token is reused rather than rotated
# on every bootstrap.
alert_token="$(kc -n monitoring get secret pagerless-alertmanager \
	-o jsonpath='{.data.token}' 2>/dev/null | base64 --decode || true)"
[ -n "$alert_token" ] || alert_token="$(openssl rand -hex 32)"
kc -n monitoring create secret generic pagerless-alertmanager \
	--from-file=token=<(printf '%s' "$alert_token") \
	--dry-run=client -o yaml | kc apply -f -

kc -n pagerless create secret generic pagerless-credentials \
	--from-file=AI_BASE_URL=<(printf '%s' "$AI_BASE_URL") \
	--from-file=AI_API_KEY=<(printf '%s' "${AI_API_KEY:-}") \
	--from-file=AI_MODEL=<(printf '%s' "$AI_MODEL") \
	--from-file=GITHUB_TOKEN=<(printf '%s' "$GITHUB_WRITE_TOKEN") \
	--from-file=GITHUB_REPO=<(printf '%s' "$(sandbox_slug)") \
	--from-file=GITHUB_API_URL=<(printf '%s' "$GITHUB_API_URL") \
	--from-file=ALERTMANAGER_WEBHOOK_TOKEN=<(printf '%s' "$alert_token") \
	--dry-run=client -o yaml | kc apply -f -
unset alert_token

# Argo CD cannot preserve a chart-generated bootstrap token: `lookup` is empty
# under `helm template`, so the token would rotate on every sync. The chart is
# told not to create it (auth.adminSecret.create: false) and this script creates
# it once, reusing an existing token when the namespace already has one.
admin_token="$(kc -n pagerless get secret pagerless-admin-secret \
	-o jsonpath='{.data.token}' 2>/dev/null | base64 --decode || true)"
[ -n "$admin_token" ] || admin_token="$(openssl rand -hex 24)"
kc -n pagerless create secret generic pagerless-admin-secret \
	--from-file=token=<(printf '%s' "$admin_token") \
	--dry-run=client -o yaml | kc apply -f -
unset admin_token

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
	observability-alerts observability-monitors observability-dashboards model-gateway; do
	wait_for_application "$app" "" 1800
done
kc -n sandbox rollout status deployment/checkout --timeout=900s

# The v2 chart is standalone, so the Application becomes healthy once its one
# server pod is ready. There is no executor, identity provider or MCP gateway to
# wait for.
wait_for_application pagerless "" 900

# Approval is bound to the identity that runs the bootstrap, so the Portal and
# `kubectl page` have an approver without a bundled identity provider (ADR-0031).
# It runs after the chart sync, because the chart creates the Role it binds. The
# binding name is derived from the identity, so a second run updates one binding.
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

The platform is synced. The demo Targets are in the sandbox namespace and the
observability stack is in monitoring.

Open Grafana:
  kubectl --context ${KUBE_CONTEXT} -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

Open the Pagerless Portal:
  kubectl --context ${KUBE_CONTEXT} -n pagerless port-forward svc/pagerless-server 8080:8080
  kubectl --context ${KUBE_CONTEXT} -n pagerless get secret pagerless-admin-secret -o jsonpath='{.data.token}' | base64 --decode; echo

Sign in with that bootstrap token. In a terminal, the same decision path is
\`kubectl page\`, configured with \`kubectl page config set\`.

Inject a failure with: make break SCENARIO=oom
Restore the Sandbox with: make reset
EOF
