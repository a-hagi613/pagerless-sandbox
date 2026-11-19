#!/usr/bin/env bash
# Restores the Sandbox's demo tree to the known-good tag, then waits for Argo CD
# to sync that restore and for the Targets to become healthy again.
#
# A Scenario changes at most a few paths, so a reset restores exactly those
# paths from the tag and commits the result on top of the current branch. It
# never rewinds main: a force-push to the tag would delete platform/, infra/,
# values/, scenarios/ and the workflows, because the tag predates them, and the
# teardown would then find no infra/ to destroy.
#
# This script reads the tag; it never creates, moves, or deletes it.
set -euo pipefail

# shellcheck source=hack/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_versions
load_env

require_env SANDBOX_URL GITHUB_WRITE_TOKEN
require_commands git
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# reset_paths prints the paths a reset restores:
#
#   - the file every scenarios/*/inject.patch edits, parsed from the patch
#     itself, so a new Scenario is covered without editing this script;
#   - every path a Target declares as its own manifest
#     (pagerless.dev/source-path) or as a dependency
#     (pagerless.dev/depends-on-paths), because a Proposal is rendered against
#     those paths and a Rollback may revert a commit that changed them.
#
# The set is deliberately wider than "the files a patch edits": a reset must
# also undo a change Pagerless made through a pull request against a Target's
# manifest or the flags it reads.
reset_paths() {
	local patches annotations
	patches="$(grep -hE '^(---|\+\+\+) [ab]/' "$REPO_ROOT"/scenarios/*/inject.patch 2>/dev/null || true)"
	printf '%s\n' "$patches" | sed -E 's#^(---|\+\+\+) [ab]/##'
	annotations="$(grep -rhoE 'pagerless\.dev/(source-path|depends-on-paths):[[:space:]]*[^[:space:]]+' "$REPO_ROOT/workloads" 2>/dev/null || true)"
	printf '%s\n' "$annotations" | sed -E 's#^[^:]+:[[:space:]]*##' | tr ',' '\n'
}

paths="$(reset_paths | sed -E 's/[[:space:]]+$//' | grep -v '^$' | sort -u)"
[ -n "$paths" ] || die "neither a Scenario patch nor a Target path annotation was found; refusing to reset nothing."

# Scenario 9 is applied outside Git, so reset removes its experiment before it
# restores the demo tree.
bash "$REPO_ROOT/hack/cpu-stress.sh" clear

git_authenticated clone --quiet "$SANDBOX_URL" "$work/sandbox"
cd "$work/sandbox"
git_authenticated fetch --quiet origin "refs/tags/known-good:refs/tags/known-good" ||
	die "the Sandbox has no known-good tag."
known_good="$(git rev-parse --verify "refs/tags/known-good^{commit}")"
tag_object="$(git rev-parse --verify "refs/tags/known-good")"

# A path the tag does not carry was added after it, so the restoration deletes it
# rather than checking it out.
while IFS= read -r path; do
	[ -n "$path" ] || continue
	if git cat-file -e "${known_good}:${path}" 2>/dev/null; then
		git checkout --quiet "$known_good" -- "$path"
	else
		git rm --quiet --force --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
		rm -f -- "$path"
	fi
	git add --all -- "$path"
done <<<"$paths"

# A restored path outside workloads/ is not expected here, but it is not a reason
# to skip the restoration: it is a reason to say so in the commit and the output.
outside="$(printf '%s\n' "$paths" | grep -v '^workloads/' || true)"

if git diff --cached --quiet; then
	echo "The Sandbox demo tree already matches known-good (${known_good}); nothing to commit."
	reset_commit="$(git rev-parse HEAD)"
else
	{
		printf 'Restore the Sandbox demo tree to known-good\n\n'
		printf 'A reset restores the paths a Scenario can change from the known-good tag\n'
		printf '(%s) instead of rewinding main to it:\n\n' "$known_good"
		while IFS= read -r path; do
			[ -n "$path" ] && printf '    %s\n' "$path"
		done <<<"$paths"
		printf '\nThe set is every file a scenarios/*/inject.patch edits, plus every path a\n'
		printf 'Target declares as pagerless.dev/source-path or\n'
		printf 'pagerless.dev/depends-on-paths, which is where a Proposal and a Rollback\n'
		printf 'write. Only the paths whose bytes differ are in this commit. Rewinding\n'
		printf 'main to the tag would instead delete platform/, infra/, values/,\n'
		printf 'scenarios/ and the workflows, because the tag predates them, and the\n'
		printf 'teardown would find no infra/ to destroy.\n\n'
		if [ -n "$outside" ]; then
			printf 'This reset also restores paths outside workloads/:\n\n'
			while IFS= read -r path; do
				[ -n "$path" ] && printf '    %s\n' "$path"
			done <<<"$outside"
			printf '\n'
		fi
		printf 'The known-good tag is unchanged: refs/tags/known-good is still %s.\n' "$tag_object"
	} >"$work/message"
	git commit --quiet --file "$work/message"
	reset_commit="$(git rev-parse HEAD)"
	git_authenticated push --quiet origin "${reset_commit}:refs/heads/main"
	echo "Restored the Sandbox demo tree from known-good (${known_good}) as ${reset_commit}."
fi

cd "$REPO_ROOT"
wait_for_application sandbox "$reset_commit" 300 healthy

# The demo's flagd pod mounts its ConfigMap, and the flag-driven services resolve a
# flag when they start, so the known-good flags reach the demo only when their pods
# are replaced. Without this step a Scenario's flag would outlive the reset even
# though the Sandbox is at known-good. flagd is replaced first, so the services
# that start after it read the restored flags.
for workload in flagd cart payment product-catalog email; do
	kc -n sandbox delete pod -l "opentelemetry.io/name=$workload" --ignore-not-found --wait=true
	kc -n sandbox rollout status "deployment/$workload" --timeout=180s
done

echo "The Sandbox demo tree is at known-good and the demo is healthy."
