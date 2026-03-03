#!/bin/sh
# pc-vm-offer-review.sh -- Display a human-readable summary of an offer
#
# Usage: pc-vm-offer-review.sh [-e externalId | -f file.json] [-t draft|preview|live]

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/config.sh"
. "${SCRIPT_DIR}/subr.sh"
. "${SCRIPT_DIR}/pc-subr.sh"

usage() {
	cat >&2 <<'EOF'
Usage: pc-vm-offer-review.sh [-e externalId | -f file.json] [-t draft|preview|live]

  -e EXTID   Fetch offer from Partner Center API
  -f FILE    Read from local JSON file (resource-tree or configure request)
  -t TYPE    Target type for API fetch (default: draft)
EOF
	exit 1
}

EXT_ID=""
INPUT_FILE=""
TARGET_TYPE="draft"

while [ $# -gt 0 ]; do
	case "$1" in
	-e) EXT_ID="$(pc_resolve_ext_id "$2")"; shift 2 ;;
	-f) INPUT_FILE="$2"; shift 2 ;;
	-t) TARGET_TYPE="$2"; shift 2 ;;
	-h|--help) usage ;;
	*) echo "Unknown option: $1" >&2; usage ;;
	esac
done

[ -n "$EXT_ID" ] || [ -n "$INPUT_FILE" ] || { echo "ERROR: -e or -f is required" >&2; usage; }

# Load JSON
if [ -n "$INPUT_FILE" ]; then
	[ -f "$INPUT_FILE" ] || pc_die "File not found: $INPUT_FILE"
	_json="$(cat "$INPUT_FILE")"
else
	pc_check_prereqs
	_durable="$(pc_get_product_durable_id "$EXT_ID")"
	_json="$(pc_get_resource_tree "$_durable" "$TARGET_TYPE")"
fi

# The resources array may be at .resources (both resource-tree and configure format)
printf '%s' "$_json" | jq -r '
	# Extract resources array
	.resources as $res |

	# --- Product ---
	($res[] | select(."$schema" | test("schema/product/"))) as $prod |
	"=== Product ===",
	"  External ID:  \($prod.identity.externalId // $prod.identity.externalID // "N/A")",
	"  Alias:        \($prod.alias // "N/A")",
	"  Type:         \($prod.type // "N/A")",
	(if $prod.resourceName then "  resourceName: \($prod.resourceName)" else empty end),
	(if $prod.id then "  Durable ID:   \($prod.id)" else empty end),
	"",

	# --- Plans ---
	"=== Plans ===",
	([$res[] | select(."$schema" | test("schema/plan/"))] | to_entries[] |
		.value as $plan |
		"  [\(.key + 1)] \($plan.identity.externalId // "N/A")",
		"      Alias:        \($plan.alias // "N/A")",
		(if $plan.resourceName then "      resourceName: \($plan.resourceName)" else empty end),
		(if $plan.id then "      Durable ID:   \($plan.id)" else empty end),
		"      Regions:      \(($plan.azureRegions // []) | join(", "))"
	),
	"",

	# --- Listing ---
	"=== Listing ===",
	([$res[] | select(."$schema" | test("schema/listing/"))][0] // null) as $listing |
	if $listing then
		"  Title:            \($listing.title // "N/A")",
		"  Search Summary:   \($listing.searchResultSummary // "N/A")",
		"  Short Description:\($listing.shortDescription // "N/A")",
		"  Privacy Policy:   \($listing.privacyPolicyLink // "N/A")",
		"  Links:",
		(($listing.generalLinks // [])[] |
			"    - \(.displayText): \(.link)"
		),
		"  Support Contact:  \(($listing.supportContact // {}) | "\(.name // "") <\(.email // "")>")",
		""
	else
		"  (no listing found)",
		""
	end,

	# --- Plan Listings ---
	"=== Plan Listings ===",
	([$res[] | select(."$schema" | test("schema/plan-listing/"))] | to_entries[] |
		.value as $pl |
		"  [\(.key + 1)] \($pl.name // "N/A")",
		"      Summary:     \($pl.summary // "N/A")",
		"      Description: \($pl.description // "N/A")"
	),
	"",

	# --- Technical Configuration ---
	"=== Technical Configuration ===",
	([$res[] | select(."$schema" | test("virtual-machine-plan-technical-configuration"))] | to_entries[] |
		.value as $tc |
		"  [Plan \(.key + 1)]",
		"    OS: \(($tc.operatingSystem // {}) | "\(.family // ""):\(.type // "")")",
		"    VM Properties:",
		(($tc.vmProperties // {}) | to_entries[] |
			"      \(.key): \(.value)"
		),
		"    SKUs:",
		(($tc.skus // [])[] |
			"      \(.imageType) -> \(.skuId)\(if .securityType then " (security: \(.securityType | join(",")))" else "" end)"
		),
		"    Image Versions: \(($tc.vmImageVersions // []) | length)",
		(($tc.vmImageVersions // [])[] |
			"      v\(.versionNumber) [\(.lifecycleState // "N/A")]:",
			((.vmImages // [])[] |
				"        \(.imageType): \(.source.sharedImage.resourceId // .source.resourcePath // "N/A")"
			)
		),
		""
	),

	# --- Preview Audiences ---
	([$res[] | select(."$schema" | test("price-and-availability-offer"))][0] // null) as $pao |
	if $pao then
		"=== Preview Audiences ===",
		(($pao.previewAudiences // [])[] |
			"  \(.type): \(.id) (\(.label // ""))"
		),
		""
	else empty end,

	# --- Submission ---
	([$res[] | select(."$schema" | test("schema/submission/"))][0] // null) as $sub |
	if $sub then
		"=== Submission ===",
		"  Target: \(($sub.target // {}).targetType // "N/A")",
		"  State:  \($sub.lifecycleState // "N/A")",
		""
	else empty end
'
