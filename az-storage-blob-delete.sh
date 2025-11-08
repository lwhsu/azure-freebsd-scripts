#!/bin/sh

set -ex

. config.sh
. subr.sh

require STORAGE_ACCOUNT_NAME
require STORAGE_ACCOUNT_CONTAINER
require STORAGE_ACCOUNT_KEY

if [ $# -eq 0 ]; then
	echo "Usage: $0 blob_name [blob_name ...]" >&2
	exit 1
fi

for blob_name in "$@"; do
	set +e
	output=$(/usr/local/bin/az storage blob delete \
		--account-key "${STORAGE_ACCOUNT_KEY}" \
		--account-name "${STORAGE_ACCOUNT_NAME}" \
		--container-name "${STORAGE_ACCOUNT_CONTAINER}" \
		--name "${blob_name}" 2>&1)
	status=$?
	set -e

	if [ $status -ne 0 ]; then
		case "$output" in
		*ErrorCode:BlobNotFound*)
			echo "Blob '${blob_name}' not found, continuing..."
			;;
		*)
			echo "An error occurred deleting '${blob_name}': $output"
			exit $status
			;;
	    esac
	fi
done
