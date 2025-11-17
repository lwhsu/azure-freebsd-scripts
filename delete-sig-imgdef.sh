#!/bin/sh

set -ex

. config.sh
. subr.sh

delete_img_versions() {
	img_def=$1

	versions=$(az sig image-version list \
		--gallery-name ${GALLERY_NAME} \
		--resource-group ${RESOURCE_GROUP} \
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
			--gallery-name ${GALLERY_NAME} \
			--resource-group ${RESOURCE_GROUP} || echo "Image version $img_def/$img_version not found, continuing..."
	done
}

VERSION=$1

require SUBSCRIPTION
require RESOURCE_GROUP
require GALLERY_NAME
require VERSION

# Define image definitions based on VERSION
set -- \
	"FreeBSD-${VERSION}-amd64-ufs-gen1" \
	"FreeBSD-${VERSION}-amd64-zfs-gen1" \
	"FreeBSD-${VERSION}-amd64-ufs-gen2" \
	"FreeBSD-${VERSION}-amd64-zfs-gen2" \
	"FreeBSD-${VERSION}-arm64-ufs-gen2" \
	"FreeBSD-${VERSION}-arm64-zfs-gen2"

# Iterate over each image definition and delete it
for img_def in "$@"; do
	delete_img_versions "$img_def"

	echo "Deleting image definition $img_def..."
	az sig image-definition delete \
		--gallery-name ${GALLERY_NAME} \
		--resource-group ${RESOURCE_GROUP} \
		--gallery-image-definition "$img_def" || echo "Image definition $img_def not found, continuing..."
	echo "Deleted image definition $img_def."
done

echo "All image definitions for version ${VERSION} have been deleted."
