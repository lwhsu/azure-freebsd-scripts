#!/bin/sh
# pc-vm-offer-create.sh -- Submit a prepared configure JSON to Partner Center
#
# Usage: pc-vm-offer-create.sh -f CONFIGURE_JSON

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/config.sh"
. "${SCRIPT_DIR}/subr.sh"
. "${SCRIPT_DIR}/pc-subr.sh"

usage() {
	cat >&2 <<'EOF'
Usage: pc-vm-offer-create.sh -f CONFIGURE_JSON
  -f FILE   The configure request JSON (output of pc-vm-offer-clone.sh)
EOF
	exit 1
}

CONFIGURE_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
	-f) CONFIGURE_FILE="$2"; shift 2 ;;
	-h|--help) usage ;;
	*) echo "Unknown option: $1" >&2; usage ;;
	esac
done

[ -n "$CONFIGURE_FILE" ] || { echo "ERROR: -f is required" >&2; usage; }
[ -f "$CONFIGURE_FILE" ] || pc_die "File not found: $CONFIGURE_FILE"

pc_check_prereqs

# Validate JSON
jq -e . "$CONFIGURE_FILE" >/dev/null 2>&1 || pc_die "Invalid JSON: $CONFIGURE_FILE"

# Show what we're about to create
echo "=== Configure Request ==="
_extid="$(jq -r '
	[.resources[] | select(.resourceName == "newProduct")] |
	first | .identity.externalId // "unknown"
' "$CONFIGURE_FILE")"
_alias="$(jq -r '
	[.resources[] | select(.resourceName == "newProduct")] |
	first | .alias // "unknown"
' "$CONFIGURE_FILE")"
_count="$(jq '.resources | length' "$CONFIGURE_FILE")"

echo "  Offer ID: ${_extid}"
echo "  Alias: ${_alias}"
echo "  Resources: ${_count}"
echo ""

printf "Submit to Partner Center? [y/N] "
read -r _confirm
case "$_confirm" in
[yY]|[yY][eE][sS]) ;;
*) echo "Aborted."; exit 0 ;;
esac

echo ""
echo "Submitting to /configure..."
_body="$(cat "$CONFIGURE_FILE")"
_resp="$(pc_configure "$_body")"

_job_id="$(printf '%s' "$_resp" | jq -r '.jobId // .jobID // empty')"
if [ -z "$_job_id" ]; then
	echo "Response:"
	printf '%s\n' "$_resp" | jq .
	pc_die "No jobId in response"
fi

echo "Job ID: ${_job_id}"
echo ""
echo "Polling for completion..."

if pc_poll_job "$_job_id" 30 60; then
	echo ""
	echo "=== Success ==="
	# Fetch job detail to get the new product durable ID
	_detail="$(pc_get_job_detail "$_job_id")"
	printf '%s\n' "$_detail" | jq -r '
		if .resources then
			(.resources[] | select(."$schema" | test("product/")) | .id // empty) as $pid |
			if $pid then "Product durable ID: \($pid)" else empty end
		else empty end
	'
	echo ""
	echo "Next steps:"
	echo "  1. Export the new offer:  NON_INTERACTIVE_OFFER=${_extid} ./pc-vm-offer-export.sh"
	echo "  2. Review:               ./pc-vm-offer-review.sh -f resource-tree_${_extid}_draft.json"
	echo "  3. Submit to preview:    ./pc-vm-offer-submit.sh -e ${_extid} -t preview"
else
	echo ""
	echo "=== Failed ==="
	_detail="$(pc_get_job_detail "$_job_id")"
	printf '%s\n' "$_detail" | jq .
	exit 1
fi
