# shellcheck shell=bash
# Shared helpers for the scripts in hack/. Sourced by each script, never executed.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${PAGERLESS_ENV_FILE:-$REPO_ROOT/.env}"

die() {
	echo "error: $*" >&2
	exit 1
}

# Loads the pinned versions from hack/versions.env into the environment.
load_versions() {
	set -a
	. "$REPO_ROOT/hack/versions.env"
	set +a
}

# Loads the local configuration from .env when it exists.
load_env() {
	if [ -f "$ENV_FILE" ]; then
		set -a
		# shellcheck source=/dev/null
		. "$ENV_FILE"
		set +a
	fi
}

# Dies with a clear message when a required variable is empty.
require_env() {
	local name
	for name in "$@"; do
		if [ -z "${!name:-}" ]; then
			die "$name is not set. Run make configure to write it to .env."
		fi
	done
}

require_commands() {
	local command_name
	for command_name in "$@"; do
		command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required for this command but was not found on PATH."
	done
}

# Runs kubectl against the showcase cluster, never the current context.
# `make cloud-up` sets PAGERLESS_KUBE_CONTEXT to target the EKS cluster instead,
# and the same helpers then wait on that cluster.
kc() {
	if [ -n "${PAGERLESS_KUBE_CONTEXT:-}" ]; then
		kubectl --context "$PAGERLESS_KUBE_CONTEXT" "$@"
	else
		kubectl --context "kind-${KIND_CLUSTER_NAME}" "$@"
	fi
}

# Prints the owner/name slug of SANDBOX_URL, for example a-hagi613/pagerless-sandbox.
sandbox_slug() {
	local slug="${SANDBOX_URL%/}"
	slug="${slug%.git}"
	echo "${slug#https://github.com/}"
}

# Git arguments that authenticate pushes with GITHUB_WRITE_TOKEN through gh,
# without placing the token in a URL or on a command line.
git_authenticated() {
	GH_TOKEN="$GITHUB_WRITE_TOKEN" git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"
}

# Waits until the Argo CD Application $1 reports Synced. When $2 is set, the
# Synced revision must equal it. When $4 is "healthy", the Application must
# also report Healthy. Times out after $3 seconds (default 300).
wait_for_application() {
	local app="$1" revision="$2" timeout="${3:-300}" want_health="${4:-healthy}"
	local deadline=$((SECONDS + timeout)) sync health current
	while :; do
		sync=$(kc -n argocd get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
		health=$(kc -n argocd get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null || true)
		current=$(kc -n argocd get application "$app" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)
		if [ "$sync" = Synced ] && { [ -z "$revision" ] || [ "$current" = "$revision" ]; } &&
			{ [ "$want_health" != healthy ] || [ "$health" = Healthy ]; }; then
			return 0
		fi
		if [ "$SECONDS" -ge "$deadline" ]; then
			die "Argo CD did not report Application $app Synced at ${revision:-any revision} within ${timeout}s (sync=$sync health=$health revision=$current)."
		fi
		sleep 2
	done
}
