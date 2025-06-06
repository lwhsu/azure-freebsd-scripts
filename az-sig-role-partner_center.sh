#!/bin/sh

set -ex

. config.sh
. subr.sh

VERSION=$1

require SUBSCRIPTION
require RESOURCE_GROUP
require GALLERY_NAME
require VERSION

# Get the Resource Id of your Azure Compute Gallery. The result is the <gallery-id>.
GALLERY_ID=$(
az sig show \
	--resource-group ${RESOURCE_GROUP} \
	--gallery-name ${GALLERY_NAME} \
	--query id -o tsv
)
#echo ${GALLERY_ID}

# Get the service principal object Id for the first Microsoft application. The result is the <sp-id1>.
SP_ID1=$(
az ad sp list --display-name "Microsoft Partner Center Resource Provider" --query '[].id' -o tsv
)
#echo ${SP_ID1}

# Create a role assignment to the first Microsoft application.
az role assignment create \
	--assignee-object-id ${SP_ID1} \
	--assignee-principal-type ServicePrincipal \
	--role cf7c76d2-98a3-4358-a134-615aa78bf44d \
	--scope ${GALLERY_ID}

# Get the service principal for the second Microsoft application. The result is the <sp-id2>.
SP_ID2=$(
az ad sp list --display-name "Compute Image Registry" --query '[].id' -o tsv
)
#echo ${SP_ID2}

# Create a role assignment to the second Microsoft application.
az role assignment create \
	--assignee-object-id ${SP_ID2} \
	--assignee-principal-type ServicePrincipal \
	--role cf7c76d2-98a3-4358-a134-615aa78bf44d \
	--scope ${GALLERY_ID}
