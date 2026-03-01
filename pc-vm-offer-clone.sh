#!/bin/sh
# pc-vm-offer-clone.sh -- Generate a new offer JSON from an existing offer (local only)
#
# Usage: pc-vm-offer-clone.sh [-s externalId | -f file.json] -t VERSION [-o ORDINAL]
#                              [-g SIG_VERSION] [--arm64-sig-version VER] [-O output.json]

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/config.sh"
. "${SCRIPT_DIR}/subr.sh"
. "${SCRIPT_DIR}/pc-subr.sh"

usage() {
	cat >&2 <<'EOF'
Usage: pc-vm-offer-clone.sh [-s externalId | -f file.json] -t VERSION
                             [-o ORDINAL] [-g SIG_VERSION]
                             [--arm64-sig-version VER] [-O output.json]

  -s EXTID       Source offer externalId (fetches current draft from API)
  -f FILE        Source resource tree JSON file (local)
  -t VERSION     Target version, e.g., "14.4"
  -o ORDINAL     Ordinal text, e.g., "fifth release"
                 Default: derived from minor version
  -g SIG_VERSION SIG image version for all architectures (e.g., 2026.0301.00)
                 Use "none" to create offer with empty vmImageVersions
                 If omitted: auto-discovers latest version from SIG via az CLI
  --arm64-sig-version VER  Override SIG version for arm64 images only
  -O FILE        Output file (default: offer-create_freebsd-{M_m}.json)
EOF
	exit 1
}

# Ordinal lookup
ordinal_for_minor() {
	case "$1" in
	0) echo "first release" ;;
	1) echo "second release" ;;
	2) echo "third release" ;;
	3) echo "fourth release" ;;
	4) echo "fifth release" ;;
	5) echo "sixth release" ;;
	6) echo "seventh release" ;;
	7) echo "eighth release" ;;
	8) echo "ninth release" ;;
	9) echo "tenth release" ;;
	*) echo "release #$(($1 + 1))" ;;
	esac
}

# Discover latest SIG image version for a given image definition
discover_sig_version() {
	_imgdef="$1"
	az sig image-version list \
		--gallery-name "${GALLERY_NAME}" \
		--gallery-image-definition "$_imgdef" \
		--resource-group "${RESOURCE_GROUP}" \
		--query "[-1].name" -o tsv 2>/dev/null || true
}

# Parse arguments
SRC_EXTID=""
SRC_FILE=""
TGT_VERSION=""
ORDINAL=""
SIG_VERSION=""
ARM64_SIG_VERSION=""
OUTPUT_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
	-s) SRC_EXTID="$2"; shift 2 ;;
	-f) SRC_FILE="$2"; shift 2 ;;
	-t) TGT_VERSION="$2"; shift 2 ;;
	-o) ORDINAL="$2"; shift 2 ;;
	-g) SIG_VERSION="$2"; shift 2 ;;
	--arm64-sig-version) ARM64_SIG_VERSION="$2"; shift 2 ;;
	-O) OUTPUT_FILE="$2"; shift 2 ;;
	-h|--help) usage ;;
	*) echo "Unknown option: $1" >&2; usage ;;
	esac
done

[ -n "$TGT_VERSION" ] || { echo "ERROR: -t VERSION is required" >&2; usage; }
[ -n "$SRC_EXTID" ] || [ -n "$SRC_FILE" ] || { echo "ERROR: -s or -f is required" >&2; usage; }

# Parse version components
TGT_MAJOR="${TGT_VERSION%%.*}"
TGT_MINOR="${TGT_VERSION#*.}"
TGT_UND="${TGT_MAJOR}_${TGT_MINOR}"
TGT_EXTID="freebsd-${TGT_UND}"

# Default ordinal
if [ -z "$ORDINAL" ]; then
	ORDINAL="$(ordinal_for_minor "$TGT_MINOR")"
fi

# Default output file
if [ -z "$OUTPUT_FILE" ]; then
	OUTPUT_FILE="offer-create_freebsd-${TGT_UND}.json"
fi

echo "Target: FreeBSD ${TGT_VERSION}-RELEASE"
echo "Offer ID: ${TGT_EXTID}"
echo "Ordinal: ${ORDINAL}"
echo "Output: ${OUTPUT_FILE}"
echo ""

# Step 1: Load source resource tree
if [ -n "$SRC_FILE" ]; then
	echo "Loading source from file: ${SRC_FILE}"
	SRC_JSON="$(cat "$SRC_FILE")"
else
	echo "Fetching source offer: ${SRC_EXTID}"
	pc_check_prereqs
	_durable="$(pc_get_product_durable_id "$SRC_EXTID")"
	SRC_JSON="$(pc_get_resource_tree "$_durable" "draft")"
fi

# Step 2: Parse source version from product externalId
SRC_EXTID_PARSED="$(printf '%s' "$SRC_JSON" | jq -r '
	[.resources[] | select(."$schema" | test("schema/product/"))][0].identity.externalId // empty
')"
[ -n "$SRC_EXTID_PARSED" ] || pc_die "Cannot find product resource in source JSON"

# Extract source version: freebsd-14_3 -> 14.3 / 14_3
SRC_UND="$(echo "$SRC_EXTID_PARSED" | sed 's/^freebsd-//')"
SRC_DOT="$(echo "$SRC_UND" | tr '_' '.')"

echo "Source offer: ${SRC_EXTID_PARSED} (version ${SRC_DOT})"
echo ""

# Step 3: Resolve SIG image versions
# Build the sig_versions JSON object
SIG_BASE="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/galleries/${GALLERY_NAME}/images"

# Determine what SKU patterns the source offer uses
# Look at the vm-tech-config resources to find which arch/fstype/gen combos exist
SKUS_JSON="$(printf '%s' "$SRC_JSON" | jq '[
	.resources[] |
	select(."$schema" | test("virtual-machine-plan-technical-configuration")) |
	.skus[] |
	{
		imageType: .imageType,
		skuId: .skuId,
		key: (
			if .imageType == "x64Gen1" then
				(if (.skuId | test("ufs")) then "amd64-ufs-gen1"
				 elif (.skuId | test("zfs")) then "amd64-zfs-gen1"
				 else "amd64-ufs-gen1" end)
			elif .imageType == "x64Gen2" then
				(if (.skuId | test("ufs")) then "amd64-ufs-gen2"
				 elif (.skuId | test("zfs")) then "amd64-zfs-gen2"
				 else "amd64-ufs-gen2" end)
			elif .imageType == "arm64Gen2" then
				(if (.skuId | test("ufs")) then "arm64-ufs-gen2"
				 elif (.skuId | test("zfs")) then "arm64-zfs-gen2"
				 else "arm64-zfs-gen2" end)
			else "unknown" end
		)
	}
] | unique_by(.key)')"

# Collect unique keys
SKU_KEYS="$(printf '%s' "$SKUS_JSON" | jq -r '.[].key')"

if [ "$SIG_VERSION" = "none" ]; then
	echo "SIG images: none (empty vmImageVersions)"
	SIG_VERSIONS_JSON="{}"
elif [ -n "$SIG_VERSION" ]; then
	# Use provided version for all (with optional arm64 override)
	echo "SIG image version: ${SIG_VERSION}"
	SIG_VERSIONS_JSON="{}"
	for key in $SKU_KEYS; do
		_arch="${key%%-*}"
		if [ "$_arch" = "arm64" ] && [ -n "$ARM64_SIG_VERSION" ]; then
			_ver="$ARM64_SIG_VERSION"
			echo "  ${key}: ${_ver} (arm64 override)"
		else
			_ver="$SIG_VERSION"
			echo "  ${key}: ${_ver}"
		fi
		SIG_VERSIONS_JSON="$(printf '%s' "$SIG_VERSIONS_JSON" | jq --arg k "$key" --arg v "$_ver" '. + {($k): $v}')"
	done
else
	# Auto-discover from SIG
	echo "Auto-discovering SIG image versions..."
	pc_need_bin az
	SIG_VERSIONS_JSON="{}"
	_found_any=false
	for key in $SKU_KEYS; do
		_arch="$(echo "$key" | cut -d- -f1)"
		_fstype="$(echo "$key" | cut -d- -f2)"
		_gen="$(echo "$key" | cut -d- -f3)"
		_imgdef="FreeBSD-${TGT_VERSION}-RELEASE-${_arch}-${_fstype}-${_gen}"
		_ver="$(discover_sig_version "$_imgdef")"
		if [ -n "$_ver" ]; then
			echo "  ${key}: ${_ver} (from ${_imgdef})"
			SIG_VERSIONS_JSON="$(printf '%s' "$SIG_VERSIONS_JSON" | jq --arg k "$key" --arg v "$_ver" '. + {($k): $v}')"
			_found_any=true
		else
			echo "  ${key}: not found (${_imgdef})"
		fi
	done
	if [ "$_found_any" = "false" ]; then
		echo ""
		echo "WARNING: No SIG image versions found. vmImageVersions will be empty."
		echo "         Use pc-vm-offer-update.sh to add images later."
		SIG_VERSIONS_JSON="{}"
	fi
fi

echo ""

# Step 4: Run jq transformation
echo "Transforming..."
RESOURCES_JSON="$(printf '%s' "$SRC_JSON" | jq -f "${SCRIPT_DIR}/clone-offer.jq" \
	--arg src_dot "$SRC_DOT" \
	--arg tgt_dot "$TGT_VERSION" \
	--arg src_und "$SRC_UND" \
	--arg tgt_und "$TGT_UND" \
	--arg tgt_extid "$TGT_EXTID" \
	--arg ordinal "$ORDINAL" \
	--arg branch "$TGT_MAJOR" \
	--argjson sig_versions "$SIG_VERSIONS_JSON" \
	--arg sig_base "$SIG_BASE" \
	--arg tenant_id "$TENANT_ID")"

# Step 5: Wrap in /configure envelope and write output
CONFIGURE_JSON="$(printf '%s' "$RESOURCES_JSON" | jq '{
	"$schema": "https://schema.mp.microsoft.com/schema/configure/2022-03-01-preview2",
	"resources": .
}')"

printf '%s\n' "$CONFIGURE_JSON" | jq . > "$OUTPUT_FILE"

echo "Generated: ${OUTPUT_FILE}"
echo ""

# Print summary
echo "=== Summary ==="
printf '%s\n' "$CONFIGURE_JSON" | jq -r '
	.resources[] |
	if .resourceName then
		"  \(."$schema" | split("/") | .[-2])  resourceName=\(.resourceName)"
	else
		"  \(."$schema" | split("/") | .[-2])"
	end
'
echo ""
echo "Resource count: $(printf '%s' "$CONFIGURE_JSON" | jq '.resources | length')"
