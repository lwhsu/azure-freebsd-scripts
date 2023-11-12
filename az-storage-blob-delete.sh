#!/bin/sh

set -ex

. config.sh
. subr.sh

require STORAGE_ACCOUNT_NAME
require STORAGE_ACCOUNT_CONTAINER
require STORAGE_ACCOUNT_KEY

set +e
output=$(/usr/local/bin/az storage blob delete \
	--account-key ${STORAGE_ACCOUNT_KEY} \
	--account-name ${STORAGE_ACCOUNT_NAME} \
	--container-name ${STORAGE_ACCOUNT_CONTAINER} \
	--name ${1} 2>&1)
status=$?
set -e

if [ $status -ne 0 ]; then
	case "$output" in
	*ErrorCode:BlobNotFound*)
		echo "Blob not found, continuing..."
		;;
	*)
		echo "An error occurred: $output"
		exit $status
		;;
    esac
fi
