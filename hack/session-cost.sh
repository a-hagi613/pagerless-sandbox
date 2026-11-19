#!/usr/bin/env bash
# Reports what one EKS session cost, from Cost Explorer.
#
# Run it by hand, once, after the session's data has settled: Cost Explorer lags
# up to about 24 hours, and AWS bills USD 0.01 for every GetCostAndUsage request.
# For that reason the script makes exactly one request, and nothing in CI or on a
# schedule calls it. The README quotes the output and names the method it used.
#
# Usage:
#   hack/session-cost.sh --start 2026-11-18 [--method tag|service] [--end ...]
#
# Methods:
#   tag     Filter to the project=pagerless cost-allocation tag. This is the
#           figure the release prefers, and it needs the tag to be active and
#           settled for the session's dates.
#   service Group the same dates by service, with no tag filter. The account's
#           other spending is negligible outside a session (it was USD 0.0003 for
#           the first half of the month), so the service totals for the session's
#           dates are effectively the session's cost. Use this when the tag data
#           is not ready, and say so in the README rather than presenting it as a
#           tag-filtered figure.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION="$REGION"

start=""
end=""
method="tag"

while [ $# -gt 0 ]; do
	case "$1" in
	--start)
		start="${2:?--start needs a date}"
		shift 2
		;;
	--end)
		end="${2:?--end needs a date}"
		shift 2
		;;
	--method)
		method="${2:?--method needs tag or service}"
		shift 2
		;;
	*)
		echo "usage: $0 [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--method tag|service]" >&2
		exit 2
		;;
	esac
done

case "$method" in
tag | service) ;;
*)
	echo "error: --method must be tag or service." >&2
	exit 2
	;;
esac

command -v aws >/dev/null 2>&1 || {
	echo "error: the AWS CLI is required." >&2
	exit 1
}

# Cost Explorer's end date is exclusive, so the default window is the one day the
# session ran. GNU date and BSD date disagree on relative dates, so both forms
# are tried.
start="${start:-$(date -u +%Y-%m-%d)}"
if [ -z "$end" ]; then
	end="$(date -u -d "${start} + 1 day" +%Y-%m-%d 2>/dev/null || date -u -v+1d -j -f %Y-%m-%d "$start" +%Y-%m-%d)"
fi

case "$method" in
tag)
	echo "Cost Explorer, method: project=pagerless tag, ${start} to ${end} (exclusive)."
	request=(--filter '{"Tags":{"Key":"project","Values":["pagerless"]}}')
	;;
service)
	echo "Cost Explorer, method: service totals for the account, ${start} to ${end} (exclusive)."
	request=()
	;;
esac
echo "One request: it bills USD 0.01, and the data can lag up to 24 hours."

rows="$(aws ce get-cost-and-usage \
	--time-period "Start=${start},End=${end}" \
	--granularity DAILY \
	--metrics UnblendedCost \
	"${request[@]}" \
	--group-by Type=DIMENSION,Key=SERVICE \
	--query 'ResultsByTime[].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]' \
	--output text)"

if [ -z "$rows" ]; then
	echo "No cost data for that window and method. Retry once the day has settled, or use --method service."
	exit 0
fi

printf '%s\n' "$rows" | awk -F'\t' '
	{ printf "  %-48s %8.4f USD\n", $1, $2; total += $2 }
	END { printf "  %-48s %8.4f USD\n", "total", total }
'
