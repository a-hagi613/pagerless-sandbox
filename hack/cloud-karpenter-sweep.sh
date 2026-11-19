#!/usr/bin/env bash
# Deletes the two Karpenter resources that outlive a Terraform destroy: EC2
# fleets and IAM instance profiles.
#
# Karpenter creates an `instant` EC2 Fleet for the capacity it launches and an
# IAM instance profile for each node launch, and neither is in Terraform's state.
# A teardown that only destroys the stack therefore leaves both behind: the fleet
# keeps appearing in the Resource Groups tagging index, and the instance profile
# is an IAM resource the zero-residue check reports by ARN. A live teardown hit
# exactly that pair after the cluster was gone.
#
# This script needs no cluster, so it also covers a session whose control plane
# was lost. Every step tolerates an absent resource, so it is safe to run when
# nothing exists and safe to run twice:
#
#   1. delete every fleet that belongs to this session, terminating its
#      instances, then wait until EC2 reports the deletion (active, modifying and
#      already-deleted fleets all end in the same state);
#   2. delete every instance profile Karpenter created for this cluster, after
#      checking that no instance still uses it;
#   3. leave a role in place unless it is under Karpenter's own IAM path and has
#      no policies and no other profiles, and report it otherwise: forcing a role
#      with dependents either fails or removes something the session did not own.
#
# `hack/cloud-down.sh` and the nightly teardown both run it, and
# hack/cloud-karpenter-sweep-test.sh proves the four cases against a fake AWS.
set -euo pipefail

# shellcheck source=hack/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION="$REGION"
CLUSTER="${PAGERLESS_CLOUD_CLUSTER:-pagerless}"

# AWS deletes a fleet and its instances asynchronously. The deletion of an
# instant fleet is quick, but an instance termination takes a minute or two, so
# the wait is bounded rather than instant.
FLEET_ATTEMPTS="${KARPENTER_SWEEP_FLEET_ATTEMPTS:-36}"
FLEET_INTERVAL_SECONDS="${KARPENTER_SWEEP_FLEET_INTERVAL_SECONDS:-5}"

require_commands aws

session_fleet_ids() {
	local index
	# The tagging index is what made this visible in the first place: a fleet
	# that survives a destroy keeps its project tag record there.
	index="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
		--tag-filters Key=project,Values=pagerless \
		--resource-type-filters ec2:fleet \
		--query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null)" ||
		die "could not read the tagging index for EC2 fleets."
	printf '%s\n' "$index" | tr -d '\r' | tr '\t' '\n' | sed 's#.*/##' | awk 'NF'
}

fleet_belongs_to_session() {
	local id="$1" tags="$2"
	if printf '%s\n' "$tags" | grep -qE '^project[[:space:]]+pagerless$'; then
		return 0
	fi
	if printf '%s\n' "$tags" | grep -qE "^kubernetes\.io/cluster/${CLUSTER}[[:space:]]+(owned|shared)$"; then
		return 0
	fi
	if printf '%s\n' "$(session_fleet_ids)" | grep -qx -- "$id"; then
		return 0
	fi
	return 1
}

wait_for_fleet_deletion() {
	local id="$1" state attempt
	for attempt in $(seq 1 "$FLEET_ATTEMPTS"); do
		state="$(aws ec2 describe-fleets --region "$REGION" --fleet-ids "$id" \
			--query 'Fleets[0].FleetState' --output text 2>&1)" || true
		case "$state" in
		deleted | deleted_running | deleted_terminating)
			return 0
			;;
		*InvalidFleetId*NotFound* | *"no fleet found"*)
			# Already gone, which is what a rerun sees.
			return 0
			;;
		esac
		if [ "$attempt" -lt "$FLEET_ATTEMPTS" ]; then
			sleep "$FLEET_INTERVAL_SECONDS"
		fi
	done
	die "the EC2 fleet ${id} is still ${state:-unknown} after $((FLEET_ATTEMPTS * FLEET_INTERVAL_SECONDS))s."
}

delete_session_fleets() {
	local ids id tags state unsuccessful
	ids="$(aws ec2 describe-fleets --region "$REGION" \
		--query 'Fleets[].[FleetId,FleetState]' --output text)" ||
		die "could not list the EC2 fleets."
	# A rerun sees the fleet in a deleted state for about an hour, and EC2 keeps
	# it in the list. Deleting it again would only produce an error, so skip
	# every state that already starts with deleted.
	for id in $(printf '%s\n' "$ids" | tr -d '\r' | awk '$2 !~ /^deleted/ { print $1 }' | sort -u); do
		tags="$(aws ec2 describe-fleets --region "$REGION" --fleet-ids "$id" \
			--query 'Fleets[0].Tags[].[Key,Value]' --output text 2>/dev/null || true)"
		if ! fleet_belongs_to_session "$id" "$tags"; then
			echo "warning: the EC2 fleet ${id} carries no session tag; leaving it for the teardown check to name." >&2
			continue
		fi
		echo "Deleting the EC2 fleet ${id} and terminating its instances."
		unsuccessful="$(aws ec2 delete-fleets --region "$REGION" --fleet-ids "$id" \
			--terminate-instances \
			--query 'UnsuccessfulFleetDeletions[].[FleetId,ErrorCode]' --output text 2>/dev/null || true)"
		if [ -n "$(printf '%s' "$unsuccessful" | tr -d '[:space:]')" ] &&
			! printf '%s\n' "$unsuccessful" | grep -q 'InvalidFleetId'; then
			echo "warning: EC2 refused to delete the fleet ${id}: ${unsuccessful}" >&2
			continue
		fi
		wait_for_fleet_deletion "$id"
	done
}

session_instance_profiles() {
	local profiles
	profiles="$(aws iam list-instance-profiles \
		--query 'InstanceProfiles[].[InstanceProfileName,Path]' --output text)" ||
		die "could not list the IAM instance profiles."
	# Karpenter puts the profile under /karpenter/<region>/<cluster>/<uuid>/ and
	# names it <cluster>_<id>. Either marker is enough, and the path marker
	# survives a naming change.
	printf '%s\n' "$profiles" | tr -d '\r' |
		awk -v cluster="$CLUSTER" '
			$2 ~ ("^/karpenter/[^/]+/" cluster "/") { print $1; next }
			$1 ~ ("^" cluster "[_-]") { print $1 }'
}

role_dependents() {
	local role="$1"
	{
		aws iam list-attached-role-policies --role-name "$role" \
			--query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null || true
		aws iam list-role-policies --role-name "$role" \
			--query 'PolicyNames[]' --output text 2>/dev/null || true
		aws iam list-instance-profiles-for-role --role-name "$role" \
			--query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null || true
	} | tr -d '\r' | tr '\t' '\n' | awk 'NF' | paste -sd ', ' -
}

delete_session_instance_profiles() {
	local profile arn in_use roles role path dependents
	for profile in $(session_instance_profiles); do
		arn="$(aws iam get-instance-profile --instance-profile-name "$profile" \
			--query 'InstanceProfile.Arn' --output text 2>/dev/null || true)"
		if [ -z "$arn" ]; then
			# Already gone, which is what a rerun sees.
			continue
		fi
		in_use="$(aws ec2 describe-instances --region "$REGION" \
			--filters "Name=iam-instance-profile.arn,Values=${arn}" \
			"Name=instance-state-name,Values=pending,running,stopping,stopped" \
			--query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
		in_use="$(printf '%s' "$in_use" | tr -d '\r' | tr '\t' '\n' | awk 'NF' | paste -sd ' ' -)"
		if [ -n "$in_use" ]; then
			echo "warning: the instance profile ${profile} is still used by ${in_use}; leaving it for the teardown check." >&2
			continue
		fi
		roles="$(aws iam get-instance-profile --instance-profile-name "$profile" \
			--query 'InstanceProfile.Roles[].RoleName' --output text 2>/dev/null || true)"
		roles="$(printf '%s' "$roles" | tr -d '\r' | tr '\t' '\n' | awk 'NF' | paste -sd ' ' -)"
		for role in $roles; do
			aws iam remove-role-from-instance-profile --instance-profile-name "$profile" \
				--role-name "$role" >/dev/null ||
				die "could not detach the role ${role} from the instance profile ${profile}."
		done
		aws iam delete-instance-profile --instance-profile-name "$profile" >/dev/null ||
			die "could not delete the instance profile ${profile}."
		echo "Deleted the Karpenter instance profile ${profile}."
		for role in $roles; do
			if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
				# Terraform already destroyed the role the profile pointed at.
				continue
			fi
			dependents="$(role_dependents "$role")"
			if [ -n "$dependents" ]; then
				echo "warning: the instance profile ${profile} referenced the role ${role}, which still has ${dependents}; leaving the role alone." >&2
				continue
			fi
			path="$(aws iam get-role --role-name "$role" --query 'Role.Path' --output text 2>/dev/null || true)"
			case "$path" in
			/karpenter/*)
				aws iam delete-role --role-name "$role" >/dev/null ||
					die "could not delete the orphaned role ${role}."
				echo "Deleted the orphaned Karpenter role ${role}."
				;;
			*)
				echo "warning: the role ${role} has no dependents but is not under Karpenter's path; leaving it for the teardown check." >&2
				;;
			esac
		done
	done
}

delete_session_fleets
delete_session_instance_profiles
echo "The Karpenter sweep is complete: no session fleet or instance profile remains."
