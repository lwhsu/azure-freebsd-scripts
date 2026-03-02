#!/bin/sh
# pc-vm-offer-compare.sh -- Normalize and diff two resource trees
#
# Usage: pc-vm-offer-compare.sh [-v] FILE_A FILE_B

set -eu

usage() {
	cat >&2 <<'EOF'
Usage: pc-vm-offer-compare.sh [-v] FILE_A FILE_B

Normalizes both resource trees (removes durable IDs, volatile URLs, sorts
by schema type) and diffs them. Useful for verifying that a cloned offer
only differs in version-specific fields.

  -v   Open in vimdiff instead of showing a unified diff
EOF
	exit 1
}

VIMDIFF=false
while [ $# -gt 0 ]; do
	case "$1" in
	-v) VIMDIFF=true; shift ;;
	-h|--help) usage ;;
	--) shift; break ;;
	-*) echo "ERROR: Unknown option: $1" >&2; usage ;;
	*) break ;;
	esac
done

[ $# -eq 2 ] || usage
[ -f "$1" ] || { echo "ERROR: File not found: $1" >&2; exit 1; }
[ -f "$2" ] || { echo "ERROR: File not found: $2" >&2; exit 1; }

# jq filter to normalize a resource tree for comparison
NORMALIZE_FILTER='
# Extract resources array (works with both resource-tree and configure format)
.resources |

# Remove customer-leads, submission, resource-tree envelope
[
  .[] |
  select(
    (."$schema" | test("customer-leads") | not) and
    (."$schema" | test("submission") | not)
  )
] |

# Normalize each resource
[
  .[] |
  # Remove durable IDs
  del(.id) |
  # Normalize schema URLs
  ."$schema" |= gsub("product-ingestion\\.azureedge\\.net/schema/"; "schema.mp.microsoft.com/schema/") |
  # Remove volatile listing-asset URLs (they change with each export)
  if (."$schema" | test("listing-asset")) then del(.url) else . end |
  # Remove resourceName (only in configure format, not in resource-tree)
  del(.resourceName) |
  # Normalize product/plan/listing references to a generic form
  (if .product and (.product | type) == "object" then .product = "PRODUCT_REF" else . end) |
  (if .product and (.product | type) == "string" then .product = "PRODUCT_REF" else . end) |
  (if .plan and (.plan | type) == "object" then .plan = "PLAN_REF" else . end) |
  (if .plan and (.plan | type) == "string" then .plan = "PLAN_REF" else . end) |
  (if .listing and (.listing | type) == "object" then .listing = "LISTING_REF" else . end) |
  (if .listing and (.listing | type) == "string" then .listing = "LISTING_REF" else . end)
] |

# Sort by schema type for stable ordering
sort_by(."$schema")
'

_label_a="$(basename "$1")"
_label_b="$(basename "$2")"

_tmp_a="$(mktemp -t "${_label_a}.XXXXXX")"
_tmp_b="$(mktemp -t "${_label_b}.XXXXXX")"
trap 'rm -f "$_tmp_a" "$_tmp_b"' EXIT INT TERM

jq "$NORMALIZE_FILTER" "$1" > "$_tmp_a"
jq "$NORMALIZE_FILTER" "$2" > "$_tmp_b"

if [ "$VIMDIFF" = "true" ]; then
	# Open the original files directly so edits are saved to disk.
	# Pretty-print first if the file is valid JSON (vimdiff opens in-place).
	_file_a="$(realpath "$1")"
	_file_b="$(realpath "$2")"
	if jq -e . "$_file_a" >/dev/null 2>&1; then
		jq . "$_file_a" > "$_tmp_a" && cp "$_tmp_a" "$_file_a"
	fi
	if jq -e . "$_file_b" >/dev/null 2>&1; then
		jq . "$_file_b" > "$_tmp_b" && cp "$_tmp_b" "$_file_b"
	fi
	vimdiff "$_file_a" "$_file_b"
else
	_diff_output="$(diff --color=always -u --label "$_label_a" --label "$_label_b" "$_tmp_a" "$_tmp_b" || true)"

	if [ -z "$_diff_output" ]; then
		echo "(no differences after normalization)"
	elif [ -t 1 ] && command -v less >/dev/null 2>&1; then
		printf '%s\n' "$_diff_output" | less -R
	else
		printf '%s\n' "$_diff_output"
	fi
fi
