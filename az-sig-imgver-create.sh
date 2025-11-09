#!/bin/sh

#set -ex

. config.sh
. subr.sh

VERSION=$1

require SUBSCRIPTION
require RESOURCE_GROUP
require GALLERY_NAME
require STORAGE_ACCOUNT_NAME
require STORAGE_ACCOUNT_CONTAINER
require VERSION

case $2 in
amd64)
	ARCH=amd64
	;;
arm64)
	ARCH=arm64-aarch64
	;;
esac

VMFS=$3

DATE=$5

SKU_INFO=${2}-${3}-${4}

#SKU=${VERSION}-${SKU_INFO}-testing
SKU=${VERSION}-${SKU_INFO}

LOCATION=eastus
#TARGET_REGIONS="${LOCATION} southcentralus"
TARGET_REGIONS="${LOCATION}"

REVISION=00
if [ -n "${DATE}" ]; then
	IMAGE_VERSION=${DATE%????}.${DATE#????}.${REVISION}
	VHD=FreeBSD-${VERSION}-${ARCH}-${VMFS}-${DATE}.vhd
else
	IMAGE_VERSION=$(TZ=GMT date +%Y.%m%d).${REVISION}
	VHD=FreeBSD-${VERSION}-${ARCH}-${VMFS}.vhd
fi

IMAGE_NAME=FreeBSD-${SKU}

az sig image-version create \
	--verbose \
	--gallery-image-definition ${IMAGE_NAME} \
	--gallery-image-version ${IMAGE_VERSION} \
	--gallery-name ${GALLERY_NAME} \
	--resource-group ${RESOURCE_GROUP} \
	--location ${LOCATION} \
	--target-regions ${TARGET_REGIONS} \
	--os-vhd-storage-account /subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT_NAME} \
	--os-vhd-uri https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/${STORAGE_ACCOUNT_CONTAINER}/${VHD} \
	--no-wait
