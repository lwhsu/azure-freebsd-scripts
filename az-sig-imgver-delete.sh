#!/bin/sh

set -ex

. config.sh
. subr.sh

VERSION=$1
IMAGE_VERSION=$2

require SUBSCRIPTION
require RESOURCE_GROUP
require GALLERY_NAME
require VERSION

case $3 in
amd64)
	ARCH=amd64
	;;
arm64)
	ARCH=arm64
	;;
esac

VMFS=$4

SKU_INFO=${3}-${4}-${5}

#SKU=${VERSION}-${SKU_INFO}-testing
SKU=${VERSION}-${SKU_INFO}

IMAGE_NAME=FreeBSD-${SKU}

az sig image-version delete \
	--gallery-image-definition ${IMAGE_NAME} \
	--gallery-image-version ${IMAGE_VERSION} \
	--gallery-name ${GALLERY_NAME} \
	--resource-group ${RESOURCE_GROUP}