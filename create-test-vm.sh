#!/bin/sh

set -eu

. config.sh
. subr.sh

usage()
{
	echo "Usage: $0 [-n] VERSION" >&2
	echo "Example: $0 14.4" >&2
	echo "         $0 -n 14.4" >&2
	exit 1
}

sanitize_name()
{
	printf '%s' "$1" \
		| tr '[:upper:]' '[:lower:]' \
		| sed 's/[^a-z0-9-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//'
}

extract_definition_version()
{
	def="$1"
	def="${def#FreeBSD-}"
	case "${def}" in
	*-amd64-*)
		printf '%s\n' "${def%%-amd64-*}"
		;;
	*-arm64-*)
		printf '%s\n' "${def%%-arm64-*}"
		;;
	*)
		return 1
		;;
	esac
}

is_numeric_version()
{
	case "$1" in
	[0-9]*.[0-9]*)
		case "$1" in
		*[!0-9.]*|*.*.*) return 1 ;;
		*) return 0 ;;
		esac
		;;
	*)
		return 1
		;;
	esac
}

pick_best_version()
{
	base="$1"
	best_version=""
	best_pri=-1
	best_num=-1

	for IMAGE_DEFINITION in $2; do
		def_ver="$(extract_definition_version "${IMAGE_DEFINITION}")"
		[ -n "${def_ver}" ] || continue

		pri=-1
		num=0
		case "${def_ver}" in
		"${base}"|\
		"${base}-RELEASE")
			pri=3
			;;
		"${base}-RC"[0-9]*)
			pri=2
			num="${def_ver#${base}-RC}"
			case "${num}" in
			*[!0-9]*|'') continue ;;
			esac
			;;
		"${base}-BETA"[0-9]*)
			pri=1
			num="${def_ver#${base}-BETA}"
			case "${num}" in
			*[!0-9]*|'') continue ;;
			esac
			;;
		*)
			continue
			;;
		esac

		if [ "${pri}" -gt "${best_pri}" ] || \
			{ [ "${pri}" -eq "${best_pri}" ] && [ "${num}" -gt "${best_num}" ]; }; then
			best_pri="${pri}"
			best_num="${num}"
			best_version="${def_ver}"
		fi
	done

	printf '%s' "${best_version}"
}

run_or_print_cmd()
{
	if [ "${DRY_RUN}" = "true" ]; then
		cmd="$1"
		shift
		printf '%s' "${cmd}"
		for arg in "$@"; do
			printf ' %s' "${arg}"
		done
		printf '\n'
	else
		"$@"
	fi
}

DRY_RUN=false

while getopts "nh" opt; do
	case "$opt" in
	n) DRY_RUN=true ;;
	h) usage ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))

VERSION="${1:-}"
[ $# -eq 1 ] || usage

require SUBSCRIPTION
require RESOURCE_GROUP
require RESOURCE_GROUP_TEST
require GALLERY_NAME
require VERSION
require ADMIN_USERNAME
require SSH_KEY_NAME

IMAGE_DEFINITIONS="$(az sig image-definition list \
	--gallery-name "${GALLERY_NAME}" \
	--resource-group "${RESOURCE_GROUP}" \
	--query "[?starts_with(name, 'FreeBSD-${VERSION}-')].name" \
	-o tsv)"

if [ -z "${IMAGE_DEFINITIONS}" ]; then
	echo "No image definitions found for version ${VERSION} in gallery ${GALLERY_NAME}." >&2
	exit 1
fi

if is_numeric_version "${VERSION}"; then
	SELECTED_VERSION="$(pick_best_version "${VERSION}" "${IMAGE_DEFINITIONS}")"
	if [ -z "${SELECTED_VERSION}" ]; then
		echo "No RELEASE/RC/BETA image definitions found for base version ${VERSION}." >&2
		exit 1
	fi
else
	SELECTED_VERSION="${VERSION}"
fi

FILTERED_DEFINITIONS=""
for IMAGE_DEFINITION in ${IMAGE_DEFINITIONS}; do
	def_ver="$(extract_definition_version "${IMAGE_DEFINITION}")"
	[ -n "${def_ver}" ] || continue
	if [ "${def_ver}" = "${SELECTED_VERSION}" ]; then
		FILTERED_DEFINITIONS="${FILTERED_DEFINITIONS}
${IMAGE_DEFINITION}"
	fi
done

IMAGE_DEFINITIONS="$(printf '%s\n' "${FILTERED_DEFINITIONS}" | sed '/^$/d')"

if [ -z "${IMAGE_DEFINITIONS}" ]; then
	echo "No image definitions found for selected version ${SELECTED_VERSION}." >&2
	exit 1
fi

if [ "${DRY_RUN}" = "true" ]; then
	echo "Selected image definition version: ${SELECTED_VERSION}" >&2
fi

count=0
created=""

for IMAGE_DEFINITION in ${IMAGE_DEFINITIONS}; do
	LATEST_VERSION="$(az sig image-version list \
		--gallery-name "${GALLERY_NAME}" \
		--resource-group "${RESOURCE_GROUP}" \
		--gallery-image-definition "${IMAGE_DEFINITION}" \
		--query "sort_by([].{name:name}, &name)[-1].name" \
		-o tsv)"

	if [ -z "${LATEST_VERSION}" ]; then
		echo "Skip ${IMAGE_DEFINITION}: no image versions." >&2
		continue
	fi

	case "${IMAGE_DEFINITION}" in
	*-amd64-*)
		SIZE="Standard_D2s_v5"
		;;
	*-arm64-*)
		SIZE="Standard_D2ps_v5"
		;;
	*)
		echo "Skip ${IMAGE_DEFINITION}: unknown architecture in definition name." >&2
		continue
		;;
	esac

	count=$((count + 1))
	safe_def="$(sanitize_name "${IMAGE_DEFINITION#FreeBSD-}")"
	VM_NAME="test-${safe_def}"

	IMAGE_ID="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/galleries/${GALLERY_NAME}/images/${IMAGE_DEFINITION}/versions/${LATEST_VERSION}"

	if [ "${DRY_RUN}" = "false" ]; then
		echo "Creating VM ${VM_NAME} from ${IMAGE_DEFINITION}:${LATEST_VERSION} (${SIZE})..."
	fi
	run_or_print_cmd \
		az vm create \
		--resource-group "${RESOURCE_GROUP_TEST}" \
		--name "${VM_NAME}" \
		--image "${IMAGE_ID}" \
		--size "${SIZE}" \
		--admin-username "${ADMIN_USERNAME}" \
		--ssh-key-name "${SSH_KEY_NAME}" \
		--no-wait

	created="${created}
${VM_NAME} ${IMAGE_DEFINITION}:${LATEST_VERSION} ${SIZE}"
done

if [ "${count}" -eq 0 ]; then
	echo "No VM created for version ${VERSION}." >&2
	exit 1
fi

if [ "${DRY_RUN}" = "false" ]; then
	echo "Created ${count} VM(s):"
	printf '%s\n' "${created}" | sed '/^$/d'
fi
