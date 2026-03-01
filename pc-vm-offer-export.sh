#!/bin/sh
# pc-vm-offer-export.sh
# List Azure VM offers (Product Ingestion API) and export one offer's resource-tree JSON.
# Requirements: POSIX sh, curl, jq

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/config.sh"
. "${SCRIPT_DIR}/subr.sh"
. "${SCRIPT_DIR}/pc-subr.sh"

TARGET_TYPE="${TARGET_TYPE:-draft}"   # draft | preview | live
NON_INTERACTIVE_OFFER="${NON_INTERACTIVE_OFFER:-}"

pc_check_prereqs

case "$TARGET_TYPE" in draft|preview|live) ;; *) pc_die "Invalid TARGET_TYPE: $TARGET_TYPE" ;; esac

print_offer_list() {
  offers_json="$1"

  # Let jq format the output lines directly (avoid shell read/IFS pitfalls).
  lines="$(printf '%s' "$offers_json" | jq -r '
    to_entries[]
    | (.key + 1) as $n
    | "\($n|tostring)\t\(.value.identity.externalID // .value.identity.externalId // "-")\t\(.value.alias // "-")\t\(.value.type // "-")\t\(.value.id // "-")"
  ')"

  [ -n "$lines" ] || pc_die "Offer list is empty or failed to render."

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
  [ -n "$sel" ] || pc_die "No selection"
  case "$sel" in *[!0-9]* ) pc_die "Selection must be a number" ;; esac
  idx=$((sel - 1))

  extid="$(printf '%s' "$offers_json" | jq -r ".[$idx].identity.externalID // .[$idx].identity.externalId // empty")"
  [ -n "$extid" ] || pc_die "Invalid selection index (or missing identity.externalID)"
  printf '%s' "$extid"
}

offers="$(pc_list_vm_offers)"
count="$(printf '%s' "$offers" | jq -r 'length')"
[ "$count" -gt 0 ] || pc_die "No Azure VM offers found (type=azureVirtualMachine)."

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

product_durable="$(pc_get_product_durable_id "$offer_extid")"
echo "Product durable ID: $product_durable"
echo ""

tree_json="$(pc_get_resource_tree "$product_durable" "$TARGET_TYPE")"
out="resource-tree_${offer_extid}_${TARGET_TYPE}.json"
printf '%s\n' "$tree_json" > "$out"

echo "Exported resource-tree to: $out"
