#!/usr/bin/env bash
# Proves that the teardown talks to the session's cluster and never to the local
# kind one.
#
# hack/cloud-down.sh computes CLOUD_CONTEXT and then makes every cluster call
# through kc() in hack/lib.sh. kc() reads PAGERLESS_KUBE_CONTEXT and falls back to
# kind-${KIND_CLUSTER_NAME} when it is unset, so a script that computes a context
# but does not export it prints "Stopping Argo CD before removing anything it
# manages" and then dies with a nonexistent context — while the session keeps
# billing. A live teardown did exactly that.
#
# The test runs the real cloud-down.sh against a fake kubectl, aws and terraform.
# The fake kubectl refuses the kind context, as a real kubeconfig without that
# entry would, so the assertion is simply that no helper call names it. It also
# runs a copy with the export removed and requires that copy to fail the same
# assertion, which is what makes this a guard rather than a description.
#
# A static pass covers the rest of hack/: any script that computes a *_CONTEXT
# and calls kc() must export it, so a new script cannot repeat the mistake.
#
# `make check`, `make cloud-check` and the Terraform CI job run this; it needs no
# credentials and never touches an account or a cluster.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0
fail() {
	echo "error: $*" >&2
	status=1
}

# 1. Static: a script that computes a session context and calls the helper must
# export it. cloud-up.sh already did; cloud-down.sh and bootstrap-stack.sh did
# not when this check was added.
for script in "$here"/*.sh; do
	grep -qE '^[A-Z_]+CONTEXT=' "$script" || continue
	grep -qE '^[[:space:]]*kc( |$)' "$script" || continue
	if ! grep -qE '^[[:space:]]*export PAGERLESS_KUBE_CONTEXT=' "$script"; then
		fail "${script##*/} computes a context and calls kc() but never exports PAGERLESS_KUBE_CONTEXT, so its helper calls fall back to the kind cluster."
	fi
done

# 2. Behavioural: run the real script with the cloud tools faked.
bin="${work}/bin"
mkdir -p "$bin"

cat >"${bin}/kubectl" <<'FAKE_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_KUBECTL_LOG:?}"
# Only the session's context exists in this kubeconfig. A teardown that falls
# back to kind-${KIND_CLUSTER_NAME} fails here, exactly as it did live.
case " $* " in
*" --context kind-"*)
	printf 'error: context "kind-pagerless" does not exist\n' >&2
	exit 1
	;;
esac
exit 0
FAKE_KUBECTL

cat >"${bin}/aws" <<'FAKE_AWS'
#!/usr/bin/env bash
set -euo pipefail
# The teardown's account guard is the only query whose answer it reads; every
# other query returns an empty account, which is a valid empty teardown.
case "${1:-} ${2:-}" in
"sts get-caller-identity")
	printf '%s\n' 207567775100
	;;
esac
exit 0
FAKE_AWS

cat >"${bin}/terraform" <<'FAKE_TERRAFORM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_TERRAFORM_LOG:?}"
exit 0
FAKE_TERRAFORM

chmod +x "${bin}/kubectl" "${bin}/aws" "${bin}/terraform"

# teardown runs cloud-down.sh in $1 with its own logs, with the ambient
# PAGERLESS_KUBE_CONTEXT removed so the script has to set it itself.
teardown() {
	local root="$1" name="$2"
	mkdir -p "${root}/infra"
	env -u PAGERLESS_KUBE_CONTEXT \
		-u PAGERLESS_CLOUD_CONTEXT \
		PATH="${bin}:${PATH}" \
		FAKE_KUBECTL_LOG="${root}/${name}-kubectl.log" \
		FAKE_TERRAFORM_LOG="${root}/${name}-terraform.log" \
		AWS_REGION=us-east-1 \
		bash "${root}/hack/cloud-down.sh" >"${root}/${name}-out.log" 2>&1
}

# copy_scripts copies the teardown and everything it calls into a scratch root,
# so a variant can be edited without touching the repository.
copy_scripts() {
	local root="$1"
	mkdir -p "${root}/hack" "${root}/infra"
	cp "${repo_root}/hack/lib.sh" \
		"${repo_root}/hack/versions.env" \
		"${repo_root}/hack/cloud-down.sh" \
		"${repo_root}/hack/cloud-volume-sweep.sh" \
		"${repo_root}/hack/cloud-teardown-check.sh" \
		"${root}/hack/"
}

# 2a. The script under test must reach the destroy with every helper call on the
# session's context.
fixed="${work}/fixed"
copy_scripts "$fixed"
if teardown "$fixed" fixed; then
	:
else
	fail "cloud-down.sh exited non-zero against an empty, reachable session (see ${fixed}/fixed-out.log)."
fi
if grep -q -- '--context kind-' "${fixed}/fixed-kubectl.log" 2>/dev/null; then
	fail "cloud-down.sh sent a helper call to the kind cluster."
fi
if ! grep -q -- '--context pagerless-eks' "${fixed}/fixed-kubectl.log" 2>/dev/null; then
	fail "cloud-down.sh made no helper call on the session's context."
fi
if ! grep -q 'destroy' "${fixed}/fixed-terraform.log" 2>/dev/null; then
	fail "cloud-down.sh never reached the terraform destroy."
fi
if ! grep -q 'The EKS session is destroyed' "${fixed}/fixed-out.log" 2>/dev/null; then
	fail "cloud-down.sh did not report a completed teardown."
fi

# 2b. The guard must catch the bug: the same script with the export removed has
# to send its helper calls to the kind cluster.
regressed="${work}/regressed"
copy_scripts "$regressed"
sed -i.bak '/export PAGERLESS_KUBE_CONTEXT=/d' "${regressed}/hack/cloud-down.sh"
if teardown "$regressed" regressed; then
	fail "the teardown with the export removed unexpectedly succeeded; the fake kubectl no longer rejects the kind context."
fi
if ! grep -q -- '--context kind-' "${regressed}/regressed-kubectl.log" 2>/dev/null; then
	fail "removing the export did not send helper calls to the kind cluster, so this test cannot catch a regression."
fi

if [ "$status" -ne 0 ]; then
	echo "The teardown context checks failed." >&2
	exit 1
fi
echo "The teardown targets the session context, and the guard catches a missing export."
