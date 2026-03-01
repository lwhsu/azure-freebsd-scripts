#!/bin/sh
# pc-vm-offer-export.sh
# List Azure VM offers (Product Ingestion API) and export one offer's resource-tree JSON.
# Requirements: POSIX sh, curl, jq

set -eu

. config.sh
. subr.sh

GRAPH_BASE="https://graph.microsoft.com/rp/product-ingestion"
PRODUCT_VERSION="${PRODUCT_VERSION:-2022-03-01-preview3}"
TREE_VERSION="${TREE_VERSION:-2022-03-01-preview5}"

TENANT_ID="${TENANT_ID:-}"
CLIENT_ID="${CLIENT_ID:-}"
CLIENT_SECRET="${CLIENT_SECRET:-}"

TARGET_TYPE="${TARGET_TYPE:-draft}"   # draft | preview | live
MAX_PAGE_SIZE="${MAX_PAGE_SIZE:-200}"
NON_INTERACTIVE_OFFER="${NON_INTERACTIVE_OFFER:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
need_bin() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

need_bin curl
need_bin jq

[ -n "$TENANT_ID" ] || die "TENANT_ID is required"
[ -n "$CLIENT_ID" ] || die "CLIENT_ID is required"
[ -n "$CLIENT_SECRET" ] || die "CLIENT_SECRET is required"

case "$TARGET_TYPE" in draft|preview|live) ;; *) die "Invalid TARGET_TYPE: $TARGET_TYPE" ;; esac

get_token() {
  curl -fsS -X POST \
    "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "client_secret=${CLIENT_SECRET}" \
    --data-urlencode "scope=https://graph.microsoft.com/.default" \
  | jq -r '.access_token // empty'
}

AUTH_TOKEN="$(get_token)"
[ -n "$AUTH_TOKEN" ] || die "Failed to obtain access token"

api_get() {
  # Usage: api_get /product key=value key=value ...
  path="$1"; shift

  # Use curl --get + --data-urlencode to avoid manual escaping bugs
  set -- "$@"  # keep params
  curl -fsS --get \
    "${GRAPH_BASE}${path}" \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    -H "Accept: application/json" \
    $(for kv in "$@"; do
        k="${kv%%=*}"
        v="${kv#*=}"
        printf -- " --data-urlencode %s=%s" "$k" "$v"
      done)
}

jq_must() {
  # jq_must <jq-filter>  (reads JSON on stdin)
  filter="$1"
  jq -e "$filter" >/dev/null 2>&1 || die "jq failed for filter: $filter"
  jq -r "$filter"
}

api_get_url() {
  # $1: full URL
  url="$1"
  curl -fsS --get \
    "$url" \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    -H "Accept: application/json"
}

list_vm_offers_all_pages() {
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT INT TERM

  # First page
  url="${GRAPH_BASE}/product?type=azureVirtualMachine&\$maxpagesize=${MAX_PAGE_SIZE}&\$version=${PRODUCT_VERSION}"

  while :; do
    resp="$(api_get_url "$url")"
    printf '%s' "$resp" | jq -e . >/dev/null 2>&1 || die "Non-JSON response from /product"
    printf '%s\n' "$resp" >> "$tmp"

    next="$(printf '%s' "$resp" | jq -r '."@nextLink" // empty')"
    [ -n "$next" ] || break
    url="$next"
  done

  # Merge all pages' .value arrays
  jq -s 'map(.value // []) | add' "$tmp"
}

print_offer_list() {
  offers_json="$1"

  # Let jq format the output lines directly (avoid shell read/IFS pitfalls).
  lines="$(printf '%s' "$offers_json" | jq -r '
    to_entries[]
    | (.key + 1) as $n
    | "\($n|tostring)\t\(.value.identity.externalID // .value.identity.externalId // "-")\t\(.value.alias // "-")\t\(.value.type // "-")\t\(.value.id // "-")"
  ')"

  [ -n "$lines" ] || die "Offer list is empty or failed to render."

  # If "column" exists, align nicely; otherwise print raw.
  if command -v column >/dev/null 2>&1; then
    printf '%s\n' "$lines" | column -t -s "$(printf '\t')" | sed 's/^/ /'
  else
    # Simple fallback (still readable)
    printf '%s\n' "$lines"
  fi
}

pick_offer_interactive() {
  offers_json="$1"
  # This function is called via command substitution; keep selection output on
  # stdout and send UI text to stderr so users can see it.
  print_offer_list "$offers_json" >&2
  echo "" >&2
  printf "Select an offer by number: " >&2
  read -r sel
  [ -n "$sel" ] || die "No selection"
  case "$sel" in *[!0-9]* ) die "Selection must be a number" ;; esac
  idx=$((sel - 1))

  extid="$(printf '%s' "$offers_json" | jq -r ".[$idx].identity.externalID // .[$idx].identity.externalId // empty")"
  [ -n "$extid" ] || die "Invalid selection index (or missing identity.externalID)"
  printf '%s' "$extid"
}

get_product_durable_id_by_external_id() {
  extid="$1"
  resp="$(api_get "/product" \
    "externalID=${extid}" \
    "\$version=${PRODUCT_VERSION}")"

  printf '%s' "$resp" | jq -e . >/dev/null 2>&1 || die "Non-JSON response querying product by externalID"

  durable="$(printf '%s' "$resp" | jq -r '
    if has("value") then (.value[0].id // empty) else (.id // empty) end
  ')"
  [ -n "$durable" ] || die "Could not resolve product durable ID for externalID=$extid"
  printf '%s' "$durable"
}

export_resource_tree() {
  durable="$1"   # product/<guid>
  target="$2"    # draft|preview|live
  api_get "/resource-tree/${durable}" \
    "targetType=${target}" \
    "\$version=${TREE_VERSION}"
}

offers="$(list_vm_offers_all_pages)"
count="$(printf '%s' "$offers" | jq -r 'length')"
[ "$count" -gt 0 ] || die "No Azure VM offers found (type=azureVirtualMachine)."

echo "Found ${count} Azure VM offer(s):"
echo ""

if [ -n "$NON_INTERACTIVE_OFFER" ]; then
  offer_extid="$NON_INTERACTIVE_OFFER"
else
  offer_extid="$(pick_offer_interactive "$offers")"
fi

echo ""
echo "Selected offer externalID: $offer_extid"
echo "Target environment: $TARGET_TYPE"
echo ""

product_durable="$(get_product_durable_id_by_external_id "$offer_extid")"
echo "Product durable ID: $product_durable"
echo ""

tree_json="$(export_resource_tree "$product_durable" "$TARGET_TYPE")"
out="resource-tree_${offer_extid}_${TARGET_TYPE}.json"
printf '%s\n' "$tree_json" > "$out"

echo "Exported resource-tree to: $out"
