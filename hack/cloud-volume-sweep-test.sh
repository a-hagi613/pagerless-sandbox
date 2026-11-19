#!/usr/bin/env bash
# Proves that the volume sweep deletes an orphaned volume, refuses to delete one
# that is still attached, and fails when AWS cannot be read.
#
# The real sweep runs against a fake `aws` on PATH, so this needs no credentials
# and never touches an account. `make cloud-check` and the Terraform CI job run
# it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sweep="${here}/cloud-volume-sweep.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="${work}/bin"
mkdir -p "$bin"
cat >"${bin}/aws" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_STATE:?}"
case "${1:-} ${2:-}" in
"ec2 describe-volumes")
	if [ -f "${state}/query-failure" ]; then
		echo "An error occurred (AccessDenied) when calling the DescribeVolumes operation" >&2
		exit 254
	fi
	if printf '%s\n' "$*" | grep -q -- 'tag-key'; then
		cat "${state}/csi-volumes.txt" 2>/dev/null || true
	else
		cat "${state}/volumes.txt" 2>/dev/null || true
	fi
	;;
"ec2 delete-volume")
	id=""
	previous=""
	for argument in "$@"; do
		[ "$previous" = "--volume-id" ] && id="$argument"
		previous="$argument"
	done
	[ -n "$id" ] || { echo "delete-volume without an id" >&2; exit 1; }
	grep -v "^${id}" "${state}/volumes.txt" >"${state}/volumes.tmp" || true
	mv "${state}/volumes.tmp" "${state}/volumes.txt"
	printf '%s\n' "$id" >>"${state}/deleted.txt"
	;;
*)
	echo "unexpected aws invocation: $*" >&2
	exit 1
	;;
esac
FAKE
chmod +x "${bin}/aws"

failures=0
fail() {
	echo "FAIL ${1}" >&2
	shift
	sed 's/^/    /' "$@" >&2
	failures=$((failures + 1))
}

new_state() {
	local state="${work}/${1}"
	mkdir -p "$state"
	printf '%s\n' "$state"
}

# sweep_case runs the real sweep against one state directory and records whether
# it exits with the expected status.
sweep_case() {
	local name="$1" want="$2" state="$3" attempts="$4" status=0
	PATH="${bin}:${PATH}" FAKE_STATE="${state}" VOLUME_SWEEP_ATTEMPTS="$attempts" \
		VOLUME_SWEEP_INTERVAL_SECONDS=0 bash "$sweep" >"${state}/stdout" 2>"${state}/stderr" || status=$?
	if [ "$status" -ne "$want" ]; then
		fail "${name}: exit ${status}, want ${want}" "${state}/stdout" "${state}/stderr"
	fi
}

clean="$(new_state clean)"
sweep_case "a session with no volume passes" 0 "$clean" 1
grep -q 'found no EBS volume' "${clean}/stdout" ||
	fail "the empty sweep did not say what it found" "${clean}/stdout"

available="$(new_state available)"
printf 'vol-0available\tavailable\n' >"${available}/volumes.txt"
sweep_case "an orphaned volume is deleted" 0 "$available" 2
grep -q 'vol-0available' "${available}/deleted.txt" 2>/dev/null ||
	fail "the orphaned volume was not deleted" "${available}/stdout"

attached="$(new_state attached)"
printf 'vol-0attached\tin-use\n' >"${attached}/volumes.txt"
sweep_case "an attached volume is not deleted" 1 "$attached" 1
grep -q 'still attached' "${attached}/stderr" ||
	fail "the attached volume is not reported" "${attached}/stderr"
if [ -f "${attached}/deleted.txt" ]; then
	fail "an attached volume was deleted" "${attached}/deleted.txt"
fi

failed_query="$(new_state failed-query)"
: >"${failed_query}/query-failure"
sweep_case "a failed AWS query fails the sweep" 1 "$failed_query" 1
grep -q 'could not list' "${failed_query}/stderr" ||
	fail "the failed query is not reported" "${failed_query}/stderr"

if [ "$failures" -ne 0 ]; then
	echo "${failures} volume-sweep test(s) failed." >&2
	exit 1
fi
echo "The volume-sweep tests passed."
