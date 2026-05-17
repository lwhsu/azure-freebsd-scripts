#!/bin/sh

# Source helper scripts
. ./config.sh
. ./subr.sh

# Ensure required variables are set
require STORAGE_ACCOUNT_NAME
require STORAGE_ACCOUNT_CONTAINER
require STORAGE_ACCOUNT_KEY

# Color codes (only when writing to a terminal)
if [ -t 1 ]; then
	_red=$(printf '\033[31m')
	_reset=$(printf '\033[0m')
else
	_red=''
	_reset=''
fi

# Current date in seconds
current_date=$(date +%s)

# Helper function to parse date and check if older than 2 weeks
is_older_than_2_weeks() {
	file_date_seconds=$(date -j -f "%Y%m%d" "$1" "+%s")
	diff=$(( (current_date - file_date_seconds) / (60 * 60 * 24) ))
	[ "$diff" -gt 14 ]
}

# Return numeric rank: RELEASE=3000, RC[N]=2000+N, BETA[N]=1000+N
get_release_rank() {
	name="$1"
	case "$name" in
		*RELEASE*)
			echo 3000
			;;
		*RC[0-9]*)
			n=$(echo "$name" | sed -nE 's/.*RC([0-9]+).*/\1/p')
			echo $((2000 + ${n:-0}))
			;;
		*BETA[0-9]*)
			n=$(echo "$name" | sed -nE 's/.*BETA([0-9]+).*/\1/p')
			echo $((1000 + ${n:-0}))
			;;
		*)
			echo 0
			;;
	esac
}

# Fetch all blobs once into a variable
all_blobs=$(az storage blob list \
	--account-name "${STORAGE_ACCOUNT_NAME}" \
	--account-key "${STORAGE_ACCOUNT_KEY}" \
	--container-name "${STORAGE_ACCOUNT_CONTAINER}" \
	--query "[].{name:name}" -o tsv)

# Snapshot images (contain YYYYMMDD): delete if older than 2 weeks
snapshot_to_delete=$(
	printf '%s\n' "$all_blobs" | while IFS= read -r blob_name; do
		[ -z "$blob_name" ] && continue
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

# Releng images: within each group (same image, varying release stage),
# keep only the highest-ranked; delete the rest.
# Group key: blob name with release tag replaced by MARKER, so same
# arch/version images with different stages share one key.
# Rank order: RELEASE(3000) > RC[N](2000+N) > BETA[N](1000+N)
releng_to_delete=$(
	printf '%s\n' "$all_blobs" | while IFS= read -r blob_name; do
		[ -z "$blob_name" ] && continue
		case "${blob_name}" in
			*[0-9][0-9][0-9][0-9][0-1][0-9][0-3][0-9]*) continue ;;
		esac
		rank=$(get_release_rank "$blob_name")
		group=$(echo "$blob_name" | sed -E 's/RELEASE|RC[0-9]*|BETA[0-9]*/MARKER/')
		printf '%s|%06d|%s\n' "$group" "$rank" "$blob_name"
	done | sort -t'|' -k1,1 -k2,2rn | awk -F'|' '
		NF == 3 {
			if ($1 == prev_group) print $3
			prev_group = $1
		}
	'
)

echo "Images in storage:"
printf '%s\n' "$all_blobs" | while IFS= read -r blob_name; do
	[ -z "$blob_name" ] && continue
	if printf '%s\n' "$snapshot_to_delete" | grep -qxF "$blob_name"; then
		printf '  %s  %s[delete: snapshot older than 2 weeks]%s\n' "$blob_name" "$_red" "$_reset"
	elif printf '%s\n' "$releng_to_delete" | grep -qxF "$blob_name"; then
		printf '  %s  %s[delete: superseded by newer releng image]%s\n' "$blob_name" "$_red" "$_reset"
	else
		printf '  %s\n' "$blob_name"
	fi
done

if [ -z "$snapshot_to_delete" ] && [ -z "$releng_to_delete" ]; then
	echo "No files to delete."
	exit 0
fi

printf "Do you want to delete all the listed files? (y/N): "
read -r confirm
case "${confirm}" in
	[Yy]*)
		for _category in "$snapshot_to_delete" "$releng_to_delete"; do
			echo "$_category" | while IFS= read -r file; do
				[ -z "$file" ] && continue
				echo -n "Deleting ${file} ..."
				az storage blob delete \
					--account-name "${STORAGE_ACCOUNT_NAME}" \
					--account-key "${STORAGE_ACCOUNT_KEY}" \
					--container-name "${STORAGE_ACCOUNT_CONTAINER}" \
					--name "$file"
				echo " done."
			done
		done
		;;
	*)
		echo "Skipped deletion of all files."
		;;
esac
