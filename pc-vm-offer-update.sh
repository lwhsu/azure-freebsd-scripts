#!/bin/sh
# pc-vm-offer-update.sh -- Update specific resources of an existing draft offer
#
# Usage:
#   pc-vm-offer-update.sh -e EXTERNAL_ID -R RESOURCE_TYPE [-o output.json]   (extract)
#   pc-vm-offer-update.sh -e EXTERNAL_ID -r RESOURCE_FILE -d                 (diff only)
#   pc-vm-offer-update.sh -e EXTERNAL_ID -r RESOURCE_FILE                    (submit)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/config.sh"
. "${SCRIPT_DIR}/subr.sh"
. "${SCRIPT_DIR}/pc-subr.sh"

usage() {
	cat >&2 <<'EOF'
Usage:
  pc-vm-offer-update.sh -e EXTERNAL_ID -R RESOURCE_TYPE [-o output.json]
  pc-vm-offer-update.sh -e EXTERNAL_ID -r RESOURCE_FILE [-d]

Modes:
  Extract (-R TYPE):  Fetch resource type from current draft for editing
  Diff (-r FILE -d):  Compare edited resource against current draft
  Submit (-r FILE):   Show diff, confirm, then POST to /configure

  -e EXTID       Offer externalId (e.g., freebsd-14_4)
  -R TYPE        Resource type to extract (e.g., listing, plan-listing,
                 virtual-machine-plan-technical-configuration)
  -r FILE        JSON file containing resource(s) to submit
  -o FILE        Output file for extract mode (default: stdout)
  -d             Diff only, do not submit
EOF
	exit 1
}

EXT_ID=""
RESOURCE_TYPE=""
RESOURCE_FILE=""
OUTPUT_FILE=""
DIFF_ONLY=false

while [ $# -gt 0 ]; do
	case "$1" in
	-e) EXT_ID="$2"; shift 2 ;;
	-R) RESOURCE_TYPE="$2"; shift 2 ;;
	-r) RESOURCE_FILE="$2"; shift 2 ;;
	-o) OUTPUT_FILE="$2"; shift 2 ;;
	-d) DIFF_ONLY=true; shift ;;
	-h|--help) usage ;;
	*) echo "Unknown option: $1" >&2; usage ;;
	esac
done

[ -n "$EXT_ID" ] || { echo "ERROR: -e is required" >&2; usage; }

pc_check_prereqs

# Fetch current draft
echo "Fetching current draft for: ${EXT_ID}" >&2
_durable="$(pc_get_product_durable_id "$EXT_ID")"
_tree="$(pc_get_resource_tree "$_durable" "draft")"

# --- Extract mode ---
if [ -n "$RESOURCE_TYPE" ]; then
	echo "Extracting resource type: ${RESOURCE_TYPE}" >&2
	_extracted="$(printf '%s' "$_tree" | jq --arg rt "$RESOURCE_TYPE" '[
		.resources[] |
		select(."$schema" | test("schema/" + $rt + "/"))
	]')"

	_count="$(printf '%s' "$_extracted" | jq 'length')"
	if [ "$_count" -eq 0 ]; then
		pc_die "No resources of type '${RESOURCE_TYPE}' found"
	fi

	echo "Found ${_count} resource(s) of type '${RESOURCE_TYPE}'" >&2

	if [ -n "$OUTPUT_FILE" ]; then
		printf '%s\n' "$_extracted" | jq . > "$OUTPUT_FILE"
		echo "Written to: ${OUTPUT_FILE}" >&2
	else
		printf '%s\n' "$_extracted" | jq .
	fi
	exit 0
fi

# --- Diff / Submit mode ---
[ -n "$RESOURCE_FILE" ] || { echo "ERROR: -r or -R is required" >&2; usage; }
[ -f "$RESOURCE_FILE" ] || pc_die "File not found: $RESOURCE_FILE"

# Load the edited resource(s)
_edited="$(jq '.' "$RESOURCE_FILE")"

# Unwrap resource-tree or configure envelope if present,
# filtering out API-managed resources (customer-leads, submission, resource-tree)
_edited="$(printf '%s' "$_edited" | jq '
	if type == "object" and .resources then
		[.resources[] | select(
			(."$schema" | test("customer-leads|submission|listing-asset") | not) and
			(."$schema" | test("resource-tree") | not)
		)]
	elif type == "array" then .
	else [.]
	end
')"

# Determine resource type(s) from the edited file
_types="$(printf '%s' "$_edited" | jq -r '
	if type == "array" then
		[.[] | ."$schema" // empty] | unique | .[]
	else
		."$schema" // empty
	end
' | while read -r schema; do
	echo "$schema" | sed 's|.*/schema/||; s|/.*||'
done | sort -u)"

# Normalization filter for diff display (mirrors pc-vm-offer-compare.sh)
_NORM='[.[] |
	del(.id) |
	."$schema" |= gsub("product-ingestion\\.azureedge\\.net/schema/"; "schema.mp.microsoft.com/schema/") |
	if (."$schema" | test("listing-asset")) then del(.url) else . end |
	del(.resourceName) |
	(if .product then .product = "PRODUCT_REF" else . end) |
	(if .plan then .plan = "PLAN_REF" else . end) |
	(if .listing then .listing = "LISTING_REF" else . end)
] | sort_by(."$schema")'

# Build a regex pattern covering all types present in the edited file
_type_pat="$(printf '%s' "$_types" | tr '\n' '|' | sed 's/|$//')"

# Extract matching current resources and normalize both sides for diff
_tmp_current="$(mktemp)"
_tmp_edited="$(mktemp)"
trap 'rm -f "$_tmp_current" "$_tmp_edited"' EXIT INT TERM

printf '%s' "$_tree" | jq -S --arg pat "$_type_pat" \
	'[.resources[] | select(."$schema" | test("schema/(" + $pat + ")/"))] | '"$_NORM" \
	> "$_tmp_current"

printf '%s' "$_edited" | jq -S "$_NORM" > "$_tmp_edited"

echo "" >&2
echo "=== Diff (current draft vs edited, normalized) ===" >&2
_diff_out="$(diff --color=always -u \
	--label "current:${EXT_ID}" --label "edited:$(basename "$RESOURCE_FILE")" \
	"$_tmp_current" "$_tmp_edited" || true)"

if [ -z "$_diff_out" ]; then
	echo "(no differences)" >&2
	rm -f "$_tmp_current" "$_tmp_edited"
	exit 0
fi

if [ -t 1 ] && command -v less >/dev/null 2>&1; then
	printf '%s\n' "$_diff_out" | less -R
else
	printf '%s\n' "$_diff_out"
fi

echo "" >&2

if [ "$DIFF_ONLY" = "true" ]; then
	rm -f "$_tmp_current" "$_tmp_edited"
	exit 0
fi

# Confirm before submitting
printf "Submit these changes? [y/N] "
read -r _confirm
case "$_confirm" in
[yY]|[yY][eE][sS]) ;;
*) echo "Aborted."; rm -f "$_tmp_current" "$_tmp_edited"; exit 0 ;;
esac

rm -f "$_tmp_current" "$_tmp_edited"

# Build configure request: wrap resource(s) with product durable ID
_resources="$(printf '%s' "$_edited" | jq --arg pid "$_durable" '
	(if type == "array" then . else [.] end) |
	[.[] |
		# Normalize schema URLs to schema.mp.microsoft.com
		."$schema" |= gsub("https://product-ingestion\\.azureedge\\.net/schema/";
		                    "https://schema.mp.microsoft.com/schema/") |
		# Always set product reference to the resolved durable ID
		# (overrides any stale/wrong product ref from the input file)
		if (."$schema" | test("schema/product/") | not) then
			.product = $pid
		else .
		end
	]
')"

_body="$(printf '%s' "$_resources" | jq '{
	"$schema": "https://schema.mp.microsoft.com/schema/configure/2022-03-01-preview2",
	"resources": .
}')"

echo ""
echo "Submitting to /configure..."
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
	echo "Update succeeded."
else
	echo ""
	echo "Update failed."
	_detail="$(pc_get_job_detail "$_job_id")"
	printf '%s\n' "$_detail" | jq .
	exit 1
fi
