#!/usr/bin/env bash
# Fails when a session left something billable behind.
#
# The session's resources all carry project=pagerless, so the Resource Groups
# Tagging API is the one place that sees every service at once. EBS volumes are
# also queried directly, because a volume is the resource that has survived a
# real teardown: the tagging index can lag, and a volume whose tag was lost is
# still billed per GiB-month. Three kinds of resource are expected to survive a
# teardown:
#
#   - the Terraform state bucket, which outlives every session by design;
#   - the two GitHub Actions roles and the OIDC provider they trust, which the
#     nightly teardown itself runs as;
#   - the cluster's KMS key, while it waits for its deletion window, which is
#     reported with the charge it still carries instead of being ignored.
#
# A failed AWS query fails the check. An account that cannot be read is not an
# empty account, and reading an error as "nothing left" is how a volume escaped
# a teardown.
#
# The tagging index lags behind EC2 by fifteen minutes or more. A terminated
# instance, a closed Spot request, a deleted fleet, a deleted volume, and a
# deleted network interface all keep their tag record while the index catches up,
# so the check asks the owning EC2 API whether each indexed resource still
# exists. An entry whose resource EC2 reports gone is ignored; any other answer,
# including AccessDenied, counts as a failed query and fails the check.
#
# AWS deletes asynchronously, so the check retries for a bounded time before it
# gives up. It never retries past the limit: a resource that is still there
# after five minutes is a teardown failure, not a slow API.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION="$REGION"
ACCOUNT="207567775100"
STATE_BUCKET="pagerless-terraform-state-207567775100"

ATTEMPTS="${TEARDOWN_CHECK_ATTEMPTS:-10}"
INTERVAL_SECONDS="${TEARDOWN_CHECK_INTERVAL_SECONDS:-30}"

exempt=(
	"arn:aws:s3:::${STATE_BUCKET}"
	"arn:aws:iam::${ACCOUNT}:role/pagerless-github-plan"
	"arn:aws:iam::${ACCOUNT}:role/pagerless-github-destroy"
	"arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
)

is_exempt() {
	local candidate="$1" allowed
	for allowed in "${exempt[@]}"; do
		[ "$candidate" = "$allowed" ] && return 0
	done
	return 1
}

# A KMS key that is scheduled for deletion still exists for up to a week, and it
# bills USD 1 per month until the deletion completes. That is expected after a
# teardown; an enabled key is not.
is_pending_deletion() {
	local arn="$1" state
	case "$arn" in
	arn:aws:kms:*) ;;
	*) return 1 ;;
	esac
	state="$(aws kms describe-key --region "$REGION" --key-id "$arn" \
		--query 'KeyMetadata.KeyState' --output text 2>/dev/null || true)"
	[ "$state" = "PendingDeletion" ]
}

# resource_state asks whether an indexed EC2 resource still exists. It returns 0
# when it does, 1 when EC2 reports it gone, and 2 when the query itself failed,
# which the caller must not read as an empty account.
resource_state() {
	local arn="$1" kind id answer state
	kind="${arn##*:}"
	id="${kind#*/}"
	kind="${kind%%/*}"
	case "$kind" in
	instance)
		answer="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$id" \
			--query 'Reservations[].Instances[].State.Name' --output text 2>&1)" || {
			case "$answer" in
			*InvalidInstanceID.NotFound*) return 1 ;;
			*) return 2 ;;
			esac
		}
		# A terminated instance stays visible to the API for about an hour.
		for state in $answer; do
			[ "$state" = "terminated" ] && return 1
		done
		;;
	spot-instances-request)
		answer="$(aws ec2 describe-spot-instance-requests --region "$REGION" \
			--spot-instance-request-ids "$id" --query 'SpotInstanceRequests[].State' \
			--output text 2>&1)" || {
			case "$answer" in
			*InvalidSpotInstanceRequestID.NotFound*) return 1 ;;
			*) return 2 ;;
			esac
		}
		for state in $answer; do
			case "$state" in
			closed | cancelled) return 1 ;;
			esac
		done
		;;
	fleet)
		answer="$(aws ec2 describe-fleets --region "$REGION" --fleet-ids "$id" \
			--query 'Fleets[].FleetState' --output text 2>&1)" || {
			# EC2 spells this code `InvalidFleetId.NotFound`, with a lowercase
			# `d`, so match the code's stable parts rather than one spelling.
			case "$answer" in
			*InvalidFleet*NotFound*) return 1 ;;
			*) return 2 ;;
			esac
		}
		# Only a fleet whose deletion has begun is gone. An instant fleet that EC2
		# still reports as active has to be deleted, which cloud-down.sh does, so
		# it stays a leftover here.
		for state in $answer; do
			case "$state" in
			deleted | deleted_running | deleted_terminating) return 1 ;;
			esac
		done
		;;
	volume)
		answer="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$id" \
			--query 'Volumes[].State' --output text 2>&1)" || {
			case "$answer" in
			*InvalidVolume.NotFound*) return 1 ;;
			*) return 2 ;;
			esac
		}
		;;
	network-interface)
		answer="$(aws ec2 describe-network-interfaces --region "$REGION" \
			--network-interface-ids "$id" --query 'NetworkInterfaces[].Status' \
			--output text 2>&1)" || {
			case "$answer" in
			*InvalidNetworkInterfaceID.NotFound*) return 1 ;;
			*) return 2 ;;
			esac
		}
		;;
	*)
		# Every other indexed service keeps the existing any-entry-is-a-leftover
		# rule; only the asynchronous EC2 deletions above need a second look.
		return 0
		;;
	esac
	# An answer with no value means the API returned an empty collection, which
	# is the same as gone.
	[ -n "$(printf '%s' "$answer" | tr -d '[:space:]')" ] || return 1
	return 0
}

# tagged_resources prints every tagged resource that is not one of the persistent
# ones. A failed query returns non-zero instead of printing nothing.
tagged_resources() {
	local output
	output="$(aws resourcegroupstaggingapi get-resources \
		--region "$REGION" \
		--tag-filters Key=project,Values=pagerless \
		--query 'ResourceTagMappingList[].ResourceARN' \
		--output text)" || return 1
	printf '%s\n' "$output" |
		# The AWS CLI on Windows ends lines with CRLF; a carriage return would
		# defeat every comparison below.
		tr -d '\r' |
		tr '\t' '\n' |
		while IFS= read -r arn; do
			[ -n "$arn" ] || continue
			if ! is_exempt "$arn"; then
				printf '%s\n' "$arn"
			fi
		done
}

# ebs_resource_arns prints the ARNs of the session's EBS volumes: the tagged ones
# and the ones the CSI driver created. A volume whose deletion is still running
# is reported until EC2 has removed it.
ebs_resource_arns() {
	local tagged csi id
	tagged="$(aws ec2 describe-volumes --region "$REGION" \
		--filters "Name=tag:project,Values=pagerless" \
		--query 'Volumes[].VolumeId' --output text)" || return 1
	csi="$(aws ec2 describe-volumes --region "$REGION" \
		--filters "Name=tag-key,Values=kubernetes.io/created-for/pv/name" \
		--query 'Volumes[].VolumeId' --output text)" || return 1
	printf '%s\n%s\n' "$tagged" "$csi" | tr -d '\r' | tr '\t' '\n' |
		while IFS= read -r id; do
			[ -n "$id" ] || continue
			printf 'arn:aws:ec2:%s:%s:volume/%s\n' "$REGION" "$ACCOUNT" "$id"
		done
}

attempt=1
while :; do
	leftovers=()
	pending_keys=()
	unknown=()
	query_failure=0
	tagged=""
	volumes=""
	tagged="$(tagged_resources)" || {
		query_failure=1
		tagged=""
	}
	volumes="$(ebs_resource_arns)" || {
		query_failure=1
		volumes=""
	}
	while IFS= read -r arn; do
		[ -n "$arn" ] || continue
		if is_pending_deletion "$arn"; then
			pending_keys+=("$arn")
			continue
		fi
		state=0
		resource_state "$arn" || state=$?
		case "$state" in
		0) leftovers+=("$arn") ;;
		1) ;; # EC2 reports the resource gone; the tag index is behind.
		*)
			query_failure=1
			unknown+=("$arn")
			;;
		esac
	done < <(printf '%s\n%s\n' "$tagged" "$volumes" | awk 'NF' | sort -u)

	if [ "$query_failure" -eq 0 ] && [ "${#leftovers[@]}" -eq 0 ]; then
		echo "The teardown check passed: no billable resource tagged project=pagerless remains."
		if [ "${#pending_keys[@]}" -gt 0 ]; then
			printf '%s\n' "${pending_keys[@]}" | sed 's/^/  waiting for deletion: /'
			echo "Those keys bill USD 1 per month until their deletion window closes; they are not a new charge from the session."
		fi
		exit 0
	fi
	if [ "$attempt" -ge "$ATTEMPTS" ]; then
		echo "The teardown check failed: the account could not be proven clean." >&2
		if [ "$query_failure" -ne 0 ]; then
			echo "  an AWS query failed on every attempt, so nothing here says the resources are gone" >&2
		fi
		if [ "${#unknown[@]}" -gt 0 ]; then
			echo "  these indexed resources could not be read, so they are not proven gone:" >&2
			printf '%s\n' "${unknown[@]}" | sed 's/^/    /' >&2
		fi
		if [ "${#leftovers[@]}" -gt 0 ]; then
			echo "  these resources tagged project=pagerless or created by the CSI driver still exist:" >&2
			printf '%s\n' "${leftovers[@]}" | sed 's/^/    /' >&2
		fi
		echo "Destroy them, or record why they must persist, before the session ends." >&2
		exit 1
	fi
	echo "Attempt ${attempt}/${ATTEMPTS}: waiting ${INTERVAL_SECONDS}s for the remaining resources to be deleted."
	if [ "$query_failure" -ne 0 ]; then
		echo "  an AWS query failed on this attempt; retrying." >&2
	fi
	sleep "$INTERVAL_SECONDS"
	attempt=$((attempt + 1))
done
