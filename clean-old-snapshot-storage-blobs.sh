#!/bin/sh

# Source helper scripts
. ./config.sh
. ./subr.sh

# Ensure required variables are set
require STORAGE_ACCOUNT_NAME
require STORAGE_ACCOUNT_CONTAINER
require STORAGE_ACCOUNT_KEY

# Current date in seconds
current_date=$(date +%s)

# Helper function to parse date and check if older than 2 weeks
is_older_than_2_weeks() {
	file_date="$1"
	# Convert file_date (in YYYYMMDD format) to seconds since the epoch (BSD style)
	file_date_seconds=$(date -j -f "%Y%m%d" "$file_date" "+%s")
	diff=$(( (current_date - file_date_seconds) / (60 * 60 * 24) ))
	if [ "$diff" -gt 14 ]; then
		return 0  # True
	else
		return 1  # False
	fi
}

# Collect files to be deleted
to_delete_files=$(
	az storage blob list --account-name "${STORAGE_ACCOUNT_NAME}" \
		--account-key "${STORAGE_ACCOUNT_KEY}" \
		--container-name "${STORAGE_ACCOUNT_CONTAINER}" \
		--query "[].{name:name}" -o tsv | while IFS= read -r blob_name; do

		# Extract date in format YYYYMMDD from file name
		case "${blob_name}" in
			*[0-9][0-9][0-9][0-9][0-1][0-9][0-3][0-9]*)
				file_date=$(echo "${blob_name}" | grep -o '[0-9]\{8\}')
				if is_older_than_2_weeks "$file_date"; then
					echo "${blob_name}"
				fi
				;;
		esac
	done
)

# Check if there are files to delete
if [ -n "$to_delete_files" ]; then
	# List files to be deleted
	echo "The following files are older than 2 weeks and will be deleted:"
	echo "$to_delete_files" | tr ' ' '\n'

	# Ask for confirmation to delete all
	printf "Do you want to delete all the listed files? (y/N): "
	read -r confirm
	case "${confirm}" in
		[Yy]*)
			echo "$to_delete_files" | while IFS= read -r file; do
				echo -n "Deleting ${file} ..."
				az storage blob delete \
					--account-name "${STORAGE_ACCOUNT_NAME}" \
					--account-key "${STORAGE_ACCOUNT_KEY}" \
					--container-name "${STORAGE_ACCOUNT_CONTAINER}" \
					--name "$file"
				echo " done. "
			done
			;;
		*)
			echo "Skipped deletion of all files."
			;;
	esac
else
	echo "No files older than 2 weeks found for deletion."
fi
