#!/bin/sh

#set -ex

. config.sh
. subr.sh

VERSION=$1

require SUBSCRIPTION
require RESOURCE_GROUP
require GALLERY_NAME
require VERSION

# Function to list image versions for a given image definition
list_image_versions() {
    local image_definition=$1
    echo "Listing image versions for $image_definition..."
    az sig image-version list \
        --gallery-name ${GALLERY_NAME} \
        --resource-group ${RESOURCE_GROUP} \
        --gallery-image-definition "$image_definition" \
        --query "[].{name:name}" -o tsv
}

# Define image definitions based on VERSION
IMAGE_DEFINITIONS="\
	FreeBSD-${VERSION}-amd64-ufs-gen1
	FreeBSD-${VERSION}-amd64-zfs-gen1
	FreeBSD-${VERSION}-amd64-ufs-gen2
	FreeBSD-${VERSION}-amd64-zfs-gen2
	FreeBSD-${VERSION}-arm64-ufs-gen2
	FreeBSD-${VERSION}-arm64-zfs-gen2
"

# Iterate over each image definition and list its versions
for img_def in ${IMAGE_DEFINITIONS}; do
    list_image_versions "$img_def"
done
