#!/bin/sh
# pc-vm-offer-status.sh -- Check configure job or submission status
#
# Usage:
#   pc-vm-offer-status.sh -j JOB_ID [-w] [-d]
#   pc-vm-offer-status.sh -e EXTERNAL_ID

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/config.sh"
. "${SCRIPT_DIR}/subr.sh"
. "${SCRIPT_DIR}/pc-subr.sh"

usage() {
	cat >&2 <<'EOF'
Usage:
  pc-vm-offer-status.sh -j JOB_ID [-w] [-d]
  pc-vm-offer-status.sh -e EXTERNAL_ID

  -j JOB_ID    Check/poll a configure job
  -w           Wait (poll) until complete
  -d           Show full job detail (error messages)
  -e EXTID     List submissions for an offer
EOF
	exit 1
}

JOB_ID=""
EXT_ID=""
WAIT=false
DETAIL=false

while [ $# -gt 0 ]; do
	case "$1" in
	-j) JOB_ID="$2"; shift 2 ;;
	-e) EXT_ID="$(pc_resolve_ext_id "$2")"; shift 2 ;;
	-w) WAIT=true; shift ;;
	-d) DETAIL=true; shift ;;
	-h|--help) usage ;;
	*) echo "Unknown option: $1" >&2; usage ;;
	esac
done

[ -n "$JOB_ID" ] || [ -n "$EXT_ID" ] || { echo "ERROR: -j or -e is required" >&2; usage; }

pc_check_prereqs

# --- Job status mode ---
if [ -n "$JOB_ID" ]; then
	if [ "$WAIT" = "true" ]; then
		echo "Polling job ${JOB_ID}..."
		if pc_poll_job "$JOB_ID" 30 2880; then
			echo "Job succeeded."
		else
			echo "Job failed or timed out."
		fi
		echo ""
	fi

	# Always show current status
	_status="$(pc_api_get "/configure/${JOB_ID}/status" \
		"\$version=${PC_CONFIGURE_VERSION}")"
	echo "=== Job Status ==="
	printf '%s\n' "$_status" | jq -r '
		"  Job ID:     \(.jobId // .jobID // "N/A")",
		"  Status:     \(.jobStatus // "N/A")",
		"  Result:     \(.jobResult // "N/A")"
	'

	if [ "$DETAIL" = "true" ]; then
		echo ""
		_job_status="$(printf '%s' "$_status" | jq -r '.jobStatus // empty')"
		_job_result="$(printf '%s' "$_status" | jq -r '.jobResult // empty')"
		if [ "$_job_status" != "completed" ]; then
			echo "=== Job Detail ==="
			echo "  (detail only available after job completes; current status: ${_job_status})"
		elif [ "$_job_result" = "failed" ]; then
			echo "=== Job Errors ==="
			printf '%s\n' "$_status" | jq -r '
				.errors[]? |
				"  [\(.code)] \(.resourceId // "unknown"): \(.message)"
			'
		else
			echo "=== Job Detail ==="
			_detail="$(pc_get_job_detail "$JOB_ID")"
			printf '%s\n' "$_detail" | jq .
		fi
	fi

	exit 0
fi

# --- Offer submissions mode ---
echo "Fetching submissions for: ${EXT_ID}"
_durable="$(pc_get_product_durable_id "$EXT_ID")"
_guid="${_durable#product/}"

echo ""
echo "=== Publishing Status ==="
_subs="$(pc_list_submissions "$_guid")"
printf '%s' "$_subs" | jq -r '
	(.value // []) |
	if length == 0 then
		"  (no active submissions)"
	else
		.[] |
		"  \(.friendlyName // "Submission") (ID: \(.id // "N/A"))",
		"  Target:  \(([.targets[]? | .value] | join(", ")) // "N/A")",
		"  State:   \(.state // "N/A") / \(.substate // "N/A")",
		""
	end
'
