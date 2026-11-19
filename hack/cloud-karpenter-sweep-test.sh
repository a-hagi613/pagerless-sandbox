#!/usr/bin/env bash
# Proves that the Karpenter sweep deletes the two resources a destroy cannot see,
# and that it reports instead of forcing a role that still has dependents.
#
# The cases are the ones a live teardown produced or could produce:
#
#   - nothing left: the sweep passes and deletes nothing;
#   - a tagged EC2 fleet: deleted with --terminate-instances, and the sweep waits
#     through the asynchronous deletion instead of returning early;
#   - a fleet EC2 has already forgotten: treated as gone, not as a failure;
#   - an instance profile whose role Terraform already destroyed: deleted by its
#     bare name (the ARN's slashes are the IAM path, not part of the name);
#   - an instance profile still used by an instance: reported and left alone;
#   - an instance profile whose role still has an attached policy: the profile is
#     deleted, the role is reported, and nothing is forced.
#
# The real sweep runs against a fake `aws` on PATH, so this needs no credentials
# and never touches an account. `make check`, `make cloud-check` and the Terraform
# CI job run it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sweep="${here}/cloud-karpenter-sweep.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="${work}/bin"
mkdir -p "$bin"
cat >"${bin}/aws" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_STATE:?}"

note() { printf '%s\n' "$*" >>"${state}/calls.log"; }

argument() {
	local flag="$1" previous=""
	shift
	for value in "$@"; do
		[ "$previous" = "$flag" ] && { printf '%s\n' "$value"; return 0; }
		previous="$value"
	done
	return 1
}

not_found() {
	printf 'An error occurred (%s) when calling the %s operation: %s\n' "$1" "$2" "$3" >&2
	exit 254
}

case "${1:-} ${2:-}" in
"resourcegroupstaggingapi get-resources")
	cat "${state}/fleet-index.txt" 2>/dev/null || true
	;;
"ec2 describe-fleets")
	if printf '%s\n' "$*" | grep -q -- '--fleet-ids'; then
		id="$(argument --fleet-ids "$@")"
		if [ -f "${state}/${id}-missing" ]; then
			not_found InvalidFleetId.NotFound DescribeFleets "The fleet ID '${id}' does not exist."
		fi
		if printf '%s\n' "$*" | grep -q 'FleetState'; then
			if [ -f "${state}/${id}-deleting" ]; then
				polls="${state}/${id}-polls"
				count=$(( $(cat "$polls" 2>/dev/null || echo 0) + 1 ))
				printf '%s\n' "$count" >"$polls"
				# Still running on the first poll, deleted afterwards: the sweep
				# must wait rather than assume the delete was synchronous.
				if [ "$count" -lt 2 ]; then
					printf 'active\n'
					exit 0
				fi
				printf 'deleted\n'
				exit 0
			fi
			cat "${state}/${id}-state.txt" 2>/dev/null || printf 'deleted\n'
		else
			cat "${state}/${id}-tags.txt" 2>/dev/null || true
		fi
	else
		cat "${state}/fleet-ids.txt" 2>/dev/null || true
	fi
	;;
"ec2 delete-fleets")
	note "$*"
	printf '%s\n' "$*" | grep -q -- '--terminate-instances' ||
		{ echo "delete-fleets without --terminate-instances" >&2; exit 1; }
	id="$(argument --fleet-ids "$@")"
	: >"${state}/${id}-deleting"
	;;
"ec2 describe-instances")
	cat "${state}/instances.txt" 2>/dev/null || true
	;;
"iam list-instance-profiles")
	cat "${state}/profiles.txt" 2>/dev/null || true
	;;
"iam get-instance-profile")
	name="$(argument --instance-profile-name "$@")"
	awk -v name="$name" '$1 == name { found = 1 } END { exit !found }' \
		"${state}/profiles.txt" 2>/dev/null ||
		not_found NoSuchEntity GetInstanceProfile "The instance profile ${name} cannot be found."
	if printf '%s\n' "$*" | grep -q 'InstanceProfile.Arn'; then
		printf 'arn:aws:iam::207567775100:instance-profile/karpenter/us-east-1/pagerless/9d2d/%s\n' "$name"
	else
		cat "${state}/profile-${name}-roles.txt" 2>/dev/null || true
	fi
	;;
"iam remove-role-from-instance-profile")
	note "$*"
	;;
"iam delete-instance-profile")
	note "$*"
	name="$(argument --instance-profile-name "$@")"
	awk -v name="$name" '$1 != name' "${state}/profiles.txt" >"${state}/profiles.tmp" 2>/dev/null || true
	mv "${state}/profiles.tmp" "${state}/profiles.txt"
	printf '%s\n' "$name" >>"${state}/deleted-profiles.txt"
	;;
"iam get-role")
	role="$(argument --role-name "$@")"
	if [ ! -f "${state}/role-${role}-path.txt" ]; then
		not_found NoSuchEntity GetRole "The role ${role} cannot be found."
	fi
	if printf '%s\n' "$*" | grep -q 'Role.Path'; then
		cat "${state}/role-${role}-path.txt"
	fi
	;;
"iam list-attached-role-policies")
	role="$(argument --role-name "$@")"
	cat "${state}/role-${role}-attached.txt" 2>/dev/null || true
	;;
"iam list-role-policies")
	role="$(argument --role-name "$@")"
	cat "${state}/role-${role}-inline.txt" 2>/dev/null || true
	;;
"iam list-instance-profiles-for-role")
	role="$(argument --role-name "$@")"
	cat "${state}/role-${role}-profiles.txt" 2>/dev/null || true
	;;
"iam delete-role")
	note "$*"
	role="$(argument --role-name "$@")"
	printf '%s\n' "$role" >>"${state}/deleted-roles.txt"
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
	for file in "$@"; do
		sed 's/^/    /' "$file" >&2
	done
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
	local name="$1" want="$2" state="$3" status=0
	PATH="${bin}:${PATH}" FAKE_STATE="${state}" AWS_REGION=us-east-1 \
		KARPENTER_SWEEP_FLEET_INTERVAL_SECONDS=0 \
		bash "$sweep" >"${state}/stdout" 2>"${state}/stderr" || status=$?
	if [ "$status" -ne "$want" ]; then
		fail "${name}: exit ${status}, want ${want}" "${state}/stdout" "${state}/stderr"
	fi
}

# 1. Nothing left.
clean="$(new_state clean)"
# A fleet the previous run already deleted stays listed in this state for about
# an hour; a rerun must not try to delete it again.
printf 'fleet-0deleted\tdeleted\n' >"${clean}/fleet-ids.txt"
: >"${clean}/profiles.txt"
sweep_case "an empty account passes" 0 "$clean"
[ ! -f "${clean}/calls.log" ] || fail "the empty sweep called a delete" "${clean}/calls.log"

# 2. A tagged fleet, deleted and waited on through an asynchronous state change.
fleet="$(new_state fleet)"
printf 'fleet-0session\tactive\n' >"${fleet}/fleet-ids.txt"
printf 'project\tpagerless\n' >"${fleet}/fleet-0session-tags.txt"
printf 'arn:aws:ec2:us-east-1:207567775100:fleet/fleet-0session\n' >"${fleet}/fleet-index.txt"
: >"${fleet}/profiles.txt"
sweep_case "a tagged fleet is deleted" 0 "$fleet"
grep -q -- '--terminate-instances' "${fleet}/calls.log" 2>/dev/null ||
	fail "the fleet was deleted without --terminate-instances" "${fleet}/stderr"
[ -f "${fleet}/fleet-0session-polls" ] ||
	fail "the sweep did not wait for the fleet deletion" "${fleet}/stderr"

# 3. A fleet EC2 no longer knows about is gone, not a failure.
gone="$(new_state fleet-gone)"
printf 'fleet-0gone\tactive\n' >"${gone}/fleet-ids.txt"
printf 'project\tpagerless\n' >"${gone}/fleet-0gone-tags.txt"
printf 'arn:aws:ec2:us-east-1:207567775100:fleet/fleet-0gone\n' >"${gone}/fleet-index.txt"
: >"${gone}/fleet-0gone-missing"
: >"${gone}/profiles.txt"
sweep_case "an already-deleted fleet passes" 0 "$gone"

# 4. An instance profile whose role Terraform already destroyed.
profile="$(new_state profile)"
printf 'pagerless_1510278765312914201\t/karpenter/us-east-1/pagerless/90d08990-e588/\n' >"${profile}/profiles.txt"
sweep_case "an orphaned instance profile is deleted" 0 "$profile"
grep -q '^iam delete-instance-profile --instance-profile-name pagerless_1510278765312914201' \
	"${profile}/calls.log" 2>/dev/null ||
	fail "the profile was not deleted by its bare name" "${profile}/calls.log"
if grep -q 'arn:aws:iam' "${profile}/calls.log" 2>/dev/null; then
	fail "the sweep passed an ARN where IAM needs the bare name" "${profile}/calls.log"
fi

# 5. An instance profile still used by an instance is reported, not deleted.
in_use="$(new_state profile-in-use)"
printf 'pagerless_2\t/karpenter/us-east-1/pagerless/aa/\n' >"${in_use}/profiles.txt"
printf 'i-0stillrunning\n' >"${in_use}/instances.txt"
sweep_case "an in-use profile is left alone" 0 "$in_use"
grep -q 'still used by i-0stillrunning' "${in_use}/stderr" ||
	fail "the in-use profile is not reported" "${in_use}/stderr"
[ ! -f "${in_use}/deleted-profiles.txt" ] ||
	fail "an in-use profile was deleted" "${in_use}/deleted-profiles.txt"

# 6. A profile whose role still has an attached policy: profile deleted, role
#    reported and not forced.
dependent="$(new_state profile-dependent-role)"
printf 'pagerless_3\t/karpenter/us-east-1/pagerless/bb/\n' >"${dependent}/profiles.txt"
printf 'pagerless-karpenter-node\n' >"${dependent}/profile-pagerless_3-roles.txt"
printf '/\n' >"${dependent}/role-pagerless-karpenter-node-path.txt"
printf 'AmazonSSMManagedInstanceCore\n' >"${dependent}/role-pagerless-karpenter-node-attached.txt"
sweep_case "a role with dependents is reported" 0 "$dependent"
grep -q 'still has AmazonSSMManagedInstanceCore' "${dependent}/stderr" ||
	fail "the dependent role is not reported" "${dependent}/stderr"
[ ! -f "${dependent}/deleted-roles.txt" ] ||
	fail "a role with dependents was deleted" "${dependent}/deleted-roles.txt"
grep -q '^pagerless_3$' "${dependent}/deleted-profiles.txt" 2>/dev/null ||
	fail "the profile was not deleted before the role was refused" "${dependent}/calls.log"

if [ "$failures" -ne 0 ]; then
	echo "${failures} Karpenter-sweep test(s) failed." >&2
	exit 1
fi
echo "The Karpenter-sweep tests passed."
