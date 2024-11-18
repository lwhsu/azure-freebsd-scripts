#!/bin/sh

set -ex

. config.sh
. subr.sh

require STORAGE_ACCOUNT_NAME
require STORAGE_ACCOUNT_CONTAINER
require STORAGE_ACCOUNT_KEY

/usr/local/bin/az storage blob list \
	--account-key ${STORAGE_ACCOUNT_KEY} \
	--account-name ${STORAGE_ACCOUNT_NAME} \
	--container-name ${STORAGE_ACCOUNT_CONTAINER} \
	--query "[].{name:name}" -o tsv
