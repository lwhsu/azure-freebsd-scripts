#!/bin/sh
# pc-vm-offer-submit.sh -- Submit an offer to preview or go live
#
# Usage: pc-vm-offer-submit.sh -e EXTERNAL_ID -t preview|live [-s SUBMISSION_ID]

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/config.sh"
. "${SCRIPT_DIR}/subr.sh"
. "${SCRIPT_DIR}/pc-subr.sh"

usage() {
	cat >&2 <<'EOF'
Usage: pc-vm-offer-submit.sh -e EXTERNAL_ID -t preview|live [-s SUBMISSION_ID]

  -e EXTID          Offer externalId (e.g., freebsd-14_4)
  -t TARGET         Target: "preview" or "live"
  -s SUBMISSION_ID  Required for "live": the preview submission durable ID
EOF
	exit 1
}

EXT_ID=""
TARGET=""
SUBMISSION_ID=""

while [ $# -gt 0 ]; do
	case "$1" in
	-e) EXT_ID="$2"; shift 2 ;;
	-t) TARGET="$2"; shift 2 ;;
	-s) SUBMISSION_ID="$2"; shift 2 ;;
	-h|--help) usage ;;
	*) echo "Unknown option: $1" >&2; usage ;;
	esac
done

[ -n "$EXT_ID" ] || { echo "ERROR: -e is required" >&2; usage; }
[ -n "$TARGET" ] || { echo "ERROR: -t is required" >&2; usage; }

case "$TARGET" in
preview|live) ;;
*) echo "ERROR: -t must be 'preview' or 'live'" >&2; usage ;;
esac

if [ "$TARGET" = "live" ] && [ -z "$SUBMISSION_ID" ]; then
	echo "ERROR: -s SUBMISSION_ID is required for 'live' target" >&2
	usage
fi

pc_check_prereqs

echo "Resolving offer: ${EXT_ID}"
_durable="$(pc_get_product_durable_id "$EXT_ID")"
echo "Product durable ID: ${_durable}"
echo ""

# Build submission resource
if [ "$TARGET" = "preview" ]; then
	_submission="$(jq -n --arg pid "$_durable" '{
		"$schema": "https://schema.mp.microsoft.com/schema/submission/2022-03-01-preview2",
		"product": $pid,
		"target": {"targetType": "preview"}
	}')"
else
	_submission="$(jq -n --arg pid "$_durable" --arg sid "$SUBMISSION_ID" '{
		"$schema": "https://schema.mp.microsoft.com/schema/submission/2022-03-01-preview2",
		"id": $sid,
		"product": $pid,
		"target": {"targetType": "live"}
	}')"
fi

_body="$(printf '%s' "$_submission" | jq '{
	"$schema": "https://schema.mp.microsoft.com/schema/configure/2022-03-01-preview2",
	"resources": [.]
}')"

echo "Submitting to ${TARGET}..."
echo ""

printf "Confirm submit to %s? [y/N] " "$TARGET"
read -r _confirm
case "$_confirm" in
[yY]|[yY][eE][sS]) ;;
*) echo "Aborted."; exit 0 ;;
esac

_resp="$(pc_configure "$_body")"

_job_id="$(printf '%s' "$_resp" | jq -r '.jobId // .jobID // empty')"
if [ -z "$_job_id" ]; then
	echo "Response:"
	printf '%s\n' "$_resp" | jq .
	pc_die "No jobId in response"
fi

echo "Job ID: ${_job_id}"
echo ""
echo "Submission started. Use pc-vm-offer-status.sh to check progress:"
echo "  ./pc-vm-offer-status.sh -j ${_job_id} -w"
