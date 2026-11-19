#!/usr/bin/env bash
# Proves that the teardown check reports a live resource and ignores a stale
# tag-index entry, and that a failed AWS query fails the check.
#
# The Resource Groups tagging index keeps a record for up to fifteen minutes
# after EC2 deletes a resource, so the check asks EC2 about each indexed
# instance, Spot request, fleet, volume, and network interface. The cases below
# cover both answers: a resource EC2 reports gone must pass, and one it still
# reports as available, in use, running, or open must fail.
#
# The real check script runs against a fake `aws` on PATH, so this needs no
# credentials and never touches an account. `make cloud-check` and the Terraform
# CI job run it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="${here}/cloud-teardown-check.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="${work}/bin"
mkdir -p "$bin"
cat >"${bin}/aws" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_STATE:?}"

fail_with() {
	printf 'An error occurred (%s) when calling the %s operation\n' "$1" "$2" >&2
	exit 254
}

# argument prints the value that follows a flag anywhere on the command line.
argument() {
	local flag="$1" previous=""
	shift
	for value in "$@"; do
		if [ "$previous" = "$flag" ]; then
			printf '%s\n' "$value"
			return 0
		fi
		previous="$value"
	done
	return 1
}

if [ -f "${state}/query-failure" ]; then
	fail_with AccessDenied GetResources
fi

case "${1:-} ${2:-}" in
"resourcegroupstaggingapi get-resources")
	cat "${state}/tagged.txt" 2>/dev/null || true
	;;
"ec2 describe-volumes")
	if printf '%s\n' "$*" | grep -q -- '--volume-ids'; then
		id="$(argument --volume-ids "$@")"
		[ ! -f "${state}/denied-describe-volumes" ] || fail_with AccessDenied DescribeVolumes
		if [ -f "${state}/volume-${id}" ]; then
			cat "${state}/volume-${id}"
		else
			fail_with InvalidVolume.NotFound DescribeVolumes
		fi
	elif printf '%s\n' "$*" | grep -q -- 'tag-key'; then
		cat "${state}/csi-volumes.txt" 2>/dev/null || true
	else
		cat "${state}/tagged-volumes.txt" 2>/dev/null || true
	fi
	;;
"ec2 describe-network-interfaces")
	id="$(argument --network-interface-ids "$@")"
	if [ -f "${state}/eni-${id}" ]; then
		cat "${state}/eni-${id}"
	else
		fail_with InvalidNetworkInterfaceID.NotFound DescribeNetworkInterfaces
	fi
	;;
"ec2 describe-instances")
	id="$(argument --instance-ids "$@")"
	if [ -f "${state}/instance-${id}" ]; then
		cat "${state}/instance-${id}"
	else
		fail_with InvalidInstanceID.NotFound DescribeInstances
	fi
	;;
"ec2 describe-spot-instance-requests")
	id="$(argument --spot-instance-request-ids "$@")"
	if [ -f "${state}/spot-${id}" ]; then
		cat "${state}/spot-${id}"
	else
		fail_with InvalidSpotInstanceRequestID.NotFound DescribeSpotInstanceRequests
	fi
	;;
"ec2 describe-fleets")
	id="$(argument --fleet-ids "$@")"
	if [ -f "${state}/fleet-${id}" ]; then
		cat "${state}/fleet-${id}"
	else
		# EC2 returns this code with a lowercase `d` in `Id`.
		fail_with InvalidFleetId.NotFound DescribeFleets
	fi
	;;
"kms describe-key")
	cat "${state}/kms-state.txt" 2>/dev/null || true
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

# check_case runs the real check against one state directory and records whether
# it exits with the expected status.
check_case() {
	local name="$1" want="$2" state="$3" status=0
	PATH="${bin}:${PATH}" FAKE_STATE="${state}" TEARDOWN_CHECK_ATTEMPTS=1 TEARDOWN_CHECK_INTERVAL_SECONDS=0 \
		bash "$check" >"${state}/stdout" 2>"${state}/stderr" || status=$?
	if [ "$status" -ne "$want" ]; then
		fail "${name}: exit ${status}, want ${want}" "${state}/stdout" "${state}/stderr"
	fi
}

clean="$(new_state clean)"
check_case "a clean account passes" 0 "$clean"
grep -q 'The teardown check passed' "${clean}/stdout" ||
	fail "the clean case did not report a pass" "${clean}/stdout"

# The tag index is what a volume escaped through. The direct EC2 query must catch
# it even when the index says nothing is left.
tagged_volume="$(new_state tagged-volume)"
printf 'vol-0tagged\n' >"${tagged_volume}/tagged-volumes.txt"
printf 'available\n' >"${tagged_volume}/volume-vol-0tagged"
check_case "a tagged volume fails the check without the tagging index" 1 "$tagged_volume"
grep -q 'volume/vol-0tagged' "${tagged_volume}/stderr" ||
	fail "the tagged volume is not named in the failure" "${tagged_volume}/stderr"

csi_volume="$(new_state csi-volume)"
printf 'vol-0csi\n' >"${csi_volume}/csi-volumes.txt"
printf 'in-use\n' >"${csi_volume}/volume-vol-0csi"
check_case "an untagged CSI volume fails the check" 1 "$csi_volume"
grep -q 'volume/vol-0csi' "${csi_volume}/stderr" ||
	fail "the CSI volume is not named in the failure" "${csi_volume}/stderr"

failed_query="$(new_state failed-query)"
: >"${failed_query}/query-failure"
check_case "a failed AWS query fails the check" 1 "$failed_query"
grep -q 'AWS query failed' "${failed_query}/stderr" ||
	fail "the failed query is not reported" "${failed_query}/stderr"

pending="$(new_state pending-key)"
printf 'arn:aws:kms:us-east-1:207567775100:key/1234\n' >"${pending}/tagged.txt"
printf 'PendingDeletion\n' >"${pending}/kms-state.txt"
check_case "a key waiting for its deletion window passes" 0 "$pending"
grep -q 'waiting for deletion' "${pending}/stdout" ||
	fail "the pending key is not reported" "${pending}/stdout"

# Every kind of tag-index tombstone that a real teardown left behind: EC2 answers
# "not found" for the volume and the network interface, and reports the terminal
# state for the instance, the Spot request, and the fleet.
stale="$(new_state stale-index)"
cat >"${stale}/tagged.txt" <<'ARNS'
arn:aws:ec2:us-east-1:207567775100:volume/vol-0gone
arn:aws:ec2:us-east-1:207567775100:network-interface/eni-0gone
arn:aws:ec2:us-east-1:207567775100:instance/i-0gone
arn:aws:ec2:us-east-1:207567775100:spot-instances-request/sir-0gone
arn:aws:ec2:us-east-1:207567775100:fleet/fleet-0gone
ARNS
check_case "stale tag-index entries that EC2 reports gone pass" 0 "$stale"
grep -q 'The teardown check passed' "${stale}/stdout" ||
	fail "the stale index case did not report a pass" "${stale}/stdout"

finished="$(new_state finished-resources)"
cat >"${finished}/tagged.txt" <<'ARNS'
arn:aws:ec2:us-east-1:207567775100:instance/i-0terminated
arn:aws:ec2:us-east-1:207567775100:spot-instances-request/sir-0closed
arn:aws:ec2:us-east-1:207567775100:spot-instances-request/sir-0cancelled
arn:aws:ec2:us-east-1:207567775100:fleet/fleet-0deleted
ARNS
printf 'terminated\n' >"${finished}/instance-i-0terminated"
printf 'closed\n' >"${finished}/spot-sir-0closed"
printf 'cancelled\n' >"${finished}/spot-sir-0cancelled"
printf 'deleted_terminating\n' >"${finished}/fleet-fleet-0deleted"
check_case "a terminated instance, a closed Spot request, and a deleted fleet pass" 0 "$finished"

# The same resource kinds stay failures while EC2 still reports them alive.
for case_name in live-volume in-use-volume running-instance stopped-instance open-spot active-fleet; do
	state="$(new_state "$case_name")"
	case "$case_name" in
	live-volume)
		printf 'arn:aws:ec2:us-east-1:207567775100:volume/vol-0live\n' >"${state}/tagged.txt"
		printf 'available\n' >"${state}/volume-vol-0live"
		pattern='volume/vol-0live'
		;;
	in-use-volume)
		printf 'arn:aws:ec2:us-east-1:207567775100:volume/vol-0attached\n' >"${state}/tagged.txt"
		printf 'in-use\n' >"${state}/volume-vol-0attached"
		pattern='volume/vol-0attached'
		;;
	running-instance)
		printf 'arn:aws:ec2:us-east-1:207567775100:instance/i-0running\n' >"${state}/tagged.txt"
		printf 'running\n' >"${state}/instance-i-0running"
		pattern='instance/i-0running'
		;;
	stopped-instance)
		printf 'arn:aws:ec2:us-east-1:207567775100:instance/i-0stopped\n' >"${state}/tagged.txt"
		printf 'stopped\n' >"${state}/instance-i-0stopped"
		pattern='instance/i-0stopped'
		;;
	open-spot)
		printf 'arn:aws:ec2:us-east-1:207567775100:spot-instances-request/sir-0open\n' >"${state}/tagged.txt"
		printf 'open\n' >"${state}/spot-sir-0open"
		pattern='spot-instances-request/sir-0open'
		;;
	active-fleet)
		printf 'arn:aws:ec2:us-east-1:207567775100:fleet/fleet-0active\n' >"${state}/tagged.txt"
		printf 'active\n' >"${state}/fleet-fleet-0active"
		pattern='fleet/fleet-0active'
		;;
	esac
	check_case "${case_name} fails the check" 1 "$state"
	grep -q "$pattern" "${state}/stderr" ||
		fail "the ${case_name} is not named in the failure" "${state}/stderr"
done

# A read that is denied is not an answer. The indexed resource must fail the
# check rather than be mistaken for a deleted one.
denied="$(new_state denied-read)"
printf 'arn:aws:ec2:us-east-1:207567775100:volume/vol-0denied\n' >"${denied}/tagged.txt"
printf 'available\n' >"${denied}/volume-vol-0denied"
: >"${denied}/denied-describe-volumes"
check_case "an AccessDenied read of an indexed resource fails the check" 1 "$denied"
grep -q 'could not be read' "${denied}/stderr" ||
	fail "the unreadable resource is not reported as unproven" "${denied}/stderr"
grep -q 'volume/vol-0denied' "${denied}/stderr" ||
	fail "the unreadable resource is not named" "${denied}/stderr"

if [ "$failures" -ne 0 ]; then
	echo "${failures} teardown-check test(s) failed." >&2
	exit 1
fi
echo "The teardown-check tests passed."
