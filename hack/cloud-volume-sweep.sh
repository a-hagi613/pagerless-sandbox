#!/usr/bin/env bash
# Deletes the EBS volumes a teardown would otherwise leave billing.
#
# A dynamically provisioned volume is outside Terraform's state. The CSI driver
# deletes it when its claim is deleted, but that happens asynchronously, and a
# cluster that is destroyed first can no longer delete it. `make cloud-down`
# therefore sweeps the volumes directly before it destroys the stack. This does
# not need a reachable cluster: the volumes are found by tag, not through the
# Kubernetes API.
#
# Only a volume that EC2 reports as `available` is deleted. An `in-use` volume
# is attached to an instance that survived the NodeClaim deletion; deleting it
# would corrupt that instance, so the sweep fails instead.
set -euo pipefail

# shellcheck source=hack/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION="$REGION"

ATTEMPTS="${VOLUME_SWEEP_ATTEMPTS:-12}"
INTERVAL_SECONDS="${VOLUME_SWEEP_INTERVAL_SECONDS:-10}"

require_commands aws

# volume_lines prints "<volume-id> <state>" for every volume that belongs to a
# session: the ones that carry the cost-allocation tag, and the ones the EBS CSI
# driver created. A failed query fails the sweep; it must never read as "no
# volumes left".
volume_lines() {
	local tagged csi
	tagged="$(aws ec2 describe-volumes --region "$REGION" \
		--filters "Name=tag:project,Values=pagerless" \
		--query 'Volumes[].[VolumeId,State]' --output text)" ||
		die "could not list the EBS volumes tagged project=pagerless."
	csi="$(aws ec2 describe-volumes --region "$REGION" \
		--filters "Name=tag-key,Values=kubernetes.io/created-for/pv/name" \
		--query 'Volumes[].[VolumeId,State]' --output text)" ||
		die "could not list the EBS volumes the CSI driver created."
	printf '%s\n%s\n' "$tagged" "$csi" | tr -d '\r' | tr '\t' ' ' | awk 'NF' | sort -u
}

for attempt in $(seq 1 "$ATTEMPTS"); do
	lines="$(volume_lines)"
	if [ -z "$lines" ]; then
		echo "The volume sweep found no EBS volume belonging to the session."
		exit 0
	fi
	attached=0
	deleted=0
	while read -r volume state; do
		[ -n "${volume:-}" ] || continue
		case "$state" in
		available)
			echo "Deleting the orphaned EBS volume ${volume}."
			aws ec2 delete-volume --region "$REGION" --volume-id "$volume" ||
				die "could not delete the EBS volume ${volume}."
			deleted=1
			;;
		in-use)
			echo "The EBS volume ${volume} is still attached to an instance." >&2
			attached=1
			;;
		*)
			echo "Waiting for the EBS volume ${volume}, which is ${state}."
			;;
		esac
	done <<<"$lines"
	if [ "$attached" -eq 1 ]; then
		die "an EBS volume is still attached; terminate the instance that holds it, then retry the teardown."
	fi
	# A deletion is re-checked immediately; only a volume that AWS is still
	# deleting needs the interval.
	if [ "$deleted" -eq 0 ] && [ "$attempt" -lt "$ATTEMPTS" ]; then
		sleep "$INTERVAL_SECONDS"
	fi
done

remaining="$(printf '%s\n' "$lines" | tr '\n' ' ')"
die "EBS volumes belonging to the session still exist after ${ATTEMPTS} attempts: ${remaining}"
