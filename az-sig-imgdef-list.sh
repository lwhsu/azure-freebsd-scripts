#!/bin/sh

set -ex

. config.sh
. subr.sh

require SUBSCRIPTION
require RESOURCE_GROUP
require GALLERY_NAME

az sig image-definition list \
    --gallery-name ${GALLERY_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --query "[].{name:name, osType:osType, architecture:architecture, hyperVGeneration:hyperVGeneration}" -o table