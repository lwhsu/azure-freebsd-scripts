#!/bin/sh

set -eu

. config.sh
. subr.sh

require SUBSCRIPTION
require RESOURCE_GROUP
require GALLERY_NAME

if ! command -v bsddialog >/dev/null 2>&1; then
	echo "bsddialog is required but not found in PATH."
	exit 1
fi

if ! command -v az >/dev/null 2>&1; then
	echo "Azure CLI (az) is required but not found in PATH."
	exit 1
fi

delete_img_versions() {
	img_def=$1

	versions=$(az sig image-version list \
		--gallery-name "${GALLERY_NAME}" \
		--resource-group "${RESOURCE_GROUP}" \
		--gallery-image-definition "$img_def" \
		--query "[].name" -o tsv) || {
		echo "Failed to list versions for $img_def, skipping version cleanup"
		return
	}

	[ -z "$versions" ] && return

	for img_version in $versions; do
		echo "Deleting image version $img_def/$img_version..."
		az sig image-version delete \
			--gallery-image-definition "$img_def" \
			--gallery-image-version "$img_version" \
			--gallery-name "${GALLERY_NAME}" \
			--resource-group "${RESOURCE_GROUP}"
	done
}

img_defs=$(az sig image-definition list \
	--gallery-name "${GALLERY_NAME}" \
	--resource-group "${RESOURCE_GROUP}" \
	--query "[].[name, osType, architecture, hyperVGeneration]" -o tsv)

if [ -z "$img_defs" ]; then
	echo "No image definitions found in gallery ${GALLERY_NAME}."
	exit 0
fi

set --
TAB=$(printf '\t')
while IFS="$TAB" read -r name os_type arch hyperv; do
	[ -z "$name" ] && continue
	desc="os=${os_type}, arch=${arch}, hyperv=${hyperv}"
	set -- "$@" "$name" "$desc" off
done <<EOF2
$img_defs
EOF2

selected=$(bsddialog --clear --backtitle "Azure SIG Image Definition Cleanup" \
	--title "Select Image Definitions" \
	--separate-output \
	--checklist "Choose image definitions to delete (versions will be deleted first):" \
	20 110 12 "$@" 3>&1 1>&2 2>&3) || {
	status=$?
	if [ "$status" -eq 1 ] || [ "$status" -eq 255 ]; then
		echo "Cancelled."
		exit 0
	fi
	exit "$status"
}

if [ -z "$selected" ]; then
	echo "No image definitions selected."
	exit 0
fi

confirm_text=$(printf '%s\n\n%s\n' \
	"Delete the following image definitions and all their versions?" \
	"$selected")

bsddialog --title "Confirm Deletion" \
	--yesno "$confirm_text" 20 100 || {
		echo "Cancelled."
		exit 0
	}

printf '%s\n' "$selected" | while IFS= read -r selected_img; do
	[ -z "$selected_img" ] && continue
	delete_img_versions "$selected_img"

	echo "Deleting image definition $selected_img..."
	az sig image-definition delete \
		--gallery-name "${GALLERY_NAME}" \
		--resource-group "${RESOURCE_GROUP}" \
		--gallery-image-definition "$selected_img"
	echo "Deleted image definition $selected_img and its child versions."
done
