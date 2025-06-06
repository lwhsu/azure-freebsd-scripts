#!/bin/sh

set -ex

. config.sh
. subr.sh

VERSION=$1

require SUBSCRIPTION
require RESOURCE_GROUP
require GALLERY_NAME
require PUBLISHER
require VERSION

case $2 in
amd64)
	ARCH=x64
	;;
arm64)
	ARCH=Arm64
	;;
esac

VMFS=$3

case $4 in
gen1)
	GENERATION=1
	FEATURES="IsAcceleratedNetworkSupported=true"
	;;
gen2)
	GENERATION=2
	FEATURES="IsAcceleratedNetworkSupported=true DiskControllerTypes=SCSI,NVMe"
	;;
esac

SKU_INFO=${2}-${3}-${4}

#OFFER=FreeBSD-${VERSION}-testing
OFFER=FreeBSD-${VERSION}
#SKU=${VERSION}-${SKU_INFO}-testing
SKU=${VERSION}-${SKU_INFO}

IMAGE_NAME=FreeBSD-${SKU}

az sig image-definition create \
	--resource-group ${RESOURCE_GROUP} \
	--gallery-name ${GALLERY_NAME} \
	--gallery-image-definition ${IMAGE_NAME} \
	--publisher ${PUBLISHER} \
	--offer ${OFFER} \
	--sku ${SKU} \
	--os-type linux \
	--os-state Generalized \
	--hyper-v-generation V${GENERATION} \
	--architecture ${ARCH} \
	--features "${FEATURES}"
# Possible --features parameters:
# Documented at https://learn.microsoft.com/en-us/azure/virtual-machines/shared-image-galleries?wt.mc_id=knowledgesearch_inproduct_copilot-in-azure&tabs=vmsource%2Cazure-cli#image-definitions
#  DiskControllerTypes=SCSI,NVMe
#  IsHibernateSupported=true
#  IsAcceleratedNetworkSupported=true
#  SecurityType=TrustedLaunch
#  SecurityType=ConfidentialVmSupported
#  SecurityType=ConfidentialVM
#  SecurityType=TrustedLaunchSupported
#  SecurityType=TrustedLaunchAndConfidentialVmSupported
