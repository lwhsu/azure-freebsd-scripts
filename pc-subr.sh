#!/bin/sh
# pc-subr.sh -- Shared Partner Center Product Ingestion API functions
# Source this file from other pc-* scripts.
# Requires: curl, jq
# Requires variables: TENANT_ID, CLIENT_ID, CLIENT_SECRET

PC_GRAPH_BASE="https://graph.microsoft.com/rp/product-ingestion"
PC_PARTNER_BASE="https://api.partner.microsoft.com/v1.0/ingestion"
PC_PRODUCT_VERSION="${PC_PRODUCT_VERSION:-2022-03-01-preview3}"
PC_TREE_VERSION="${PC_TREE_VERSION:-2022-03-01-preview5}"
PC_CONFIGURE_VERSION="${PC_CONFIGURE_VERSION:-2022-03-01-preview2}"
PC_MAX_PAGE_SIZE="${PC_MAX_PAGE_SIZE:-200}"

PC_TOKEN=""
PC_PARTNER_TOKEN=""

pc_die() { echo "ERROR: $*" >&2; exit 1; }

# Resolve a short version string (e.g. "14.4") to a full externalId ("freebsd-14_4").
# Passes through strings that already look like full externalIds.
pc_resolve_ext_id() {
	case "$1" in
	[0-9]*.[0-9]*)
		printf 'freebsd-%s' "$(printf '%s' "$1" | tr '.' '_')"
		;;
	*)
		printf '%s' "$1"
		;;
	esac
}

pc_need_bin() {
	command -v "$1" >/dev/null 2>&1 || pc_die "Missing required command: $1"
}

pc_check_prereqs() {
	pc_need_bin curl
	pc_need_bin jq
	[ -n "$TENANT_ID" ] || pc_die "TENANT_ID is required"
	[ -n "$CLIENT_ID" ] || pc_die "CLIENT_ID is required"
	[ -n "$CLIENT_SECRET" ] || pc_die "CLIENT_SECRET is required"
}

# Obtain an OAuth2 access token via client_credentials flow
pc_get_token() {
	curl -fsS -X POST \
		"https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_id=${CLIENT_ID}" \
		--data-urlencode "client_secret=${CLIENT_SECRET}" \
		--data-urlencode "scope=https://graph.microsoft.com/.default" \
	| jq -r '.access_token // empty'
}

# Lazy token initialization -- call before any API function
pc_ensure_token() {
	if [ -z "$PC_TOKEN" ]; then
		PC_TOKEN="$(pc_get_token)"
		[ -n "$PC_TOKEN" ] || pc_die "Failed to obtain access token"
	fi
}

# Obtain an OAuth2 access token for api.partner.microsoft.com
pc_get_partner_token() {
	curl -fsS -X POST \
		"https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_id=${CLIENT_ID}" \
		--data-urlencode "client_secret=${CLIENT_SECRET}" \
		--data-urlencode "scope=https://api.partner.microsoft.com/.default" \
	| jq -r '.access_token // empty'
}

pc_ensure_partner_token() {
	if [ -z "$PC_PARTNER_TOKEN" ]; then
		PC_PARTNER_TOKEN="$(pc_get_partner_token)"
		[ -n "$PC_PARTNER_TOKEN" ] || pc_die "Failed to obtain partner API access token"
	fi
}

# GET with path relative to PC_PARTNER_BASE
pc_api_partner_get() {
	pc_ensure_partner_token
	_pc_pg_tmp="$(mktemp -t pc_pg.XXXXXX)"
	_pc_pg_http="$(curl -sS --get \
		-o "$_pc_pg_tmp" -w '%{http_code}' \
		"${PC_PARTNER_BASE}${1}" \
		-H "Authorization: Bearer ${PC_PARTNER_TOKEN}" \
		-H "Accept: application/json")"
	if [ "$_pc_pg_http" -ge 400 ]; then
		echo "ERROR: HTTP ${_pc_pg_http} from GET ${PC_PARTNER_BASE}${1}" >&2
		cat "$_pc_pg_tmp" >&2
		rm -f "$_pc_pg_tmp"
		return 1
	fi
	cat "$_pc_pg_tmp"
	rm -f "$_pc_pg_tmp"
}

# List active submissions for a product GUID via the partner API
pc_list_submissions() {
	pc_api_partner_get "/products/${1}/submissions"
}

# GET with path relative to GRAPH_BASE, plus optional key=value query params
# Usage: pc_api_get /product key=value key=value ...
pc_api_get() {
	pc_ensure_token
	_path="$1"; shift
	_pc_get_tmp="$(mktemp)"
	_pc_get_http="$(curl -sS --get \
		-o "$_pc_get_tmp" -w '%{http_code}' \
		"${PC_GRAPH_BASE}${_path}" \
		-H "Authorization: Bearer ${PC_TOKEN}" \
		-H "Accept: application/json" \
		$(for kv in "$@"; do
			k="${kv%%=*}"
			v="${kv#*=}"
			printf -- " --data-urlencode %s=%s" "$k" "$v"
		done))"
	if [ "$_pc_get_http" -ge 400 ]; then
		echo "ERROR: HTTP ${_pc_get_http} from GET ${PC_GRAPH_BASE}${_path}" >&2
		cat "$_pc_get_tmp" >&2
		rm -f "$_pc_get_tmp"
		return 1
	fi
	cat "$_pc_get_tmp"
	rm -f "$_pc_get_tmp"
}

# GET with a full URL (e.g., nextLink pagination)
pc_api_get_url() {
	pc_ensure_token
	_pc_gurl_tmp="$(mktemp)"
	_pc_gurl_http="$(curl -sS --get \
		-o "$_pc_gurl_tmp" -w '%{http_code}' \
		"$1" \
		-H "Authorization: Bearer ${PC_TOKEN}" \
		-H "Accept: application/json")"
	if [ "$_pc_gurl_http" -ge 400 ]; then
		echo "ERROR: HTTP ${_pc_gurl_http} from GET $1" >&2
		cat "$_pc_gurl_tmp" >&2
		rm -f "$_pc_gurl_tmp"
		return 1
	fi
	cat "$_pc_gurl_tmp"
	rm -f "$_pc_gurl_tmp"
}

# POST JSON to a full URL
pc_api_post() {
	pc_ensure_token
	_pc_post_tmp="$(mktemp)"
	_pc_post_http="$(curl -sS -X POST \
		-o "$_pc_post_tmp" -w '%{http_code}' \
		"$1" \
		-H "Authorization: Bearer ${PC_TOKEN}" \
		-H "Content-Type: application/json" \
		-H "Accept: application/json" \
		-d "$2")"
	if [ "$_pc_post_http" -ge 400 ]; then
		echo "ERROR: HTTP ${_pc_post_http} from POST $1" >&2
		cat "$_pc_post_tmp" >&2
		rm -f "$_pc_post_tmp"
		return 1
	fi
	cat "$_pc_post_tmp"
	rm -f "$_pc_post_tmp"
}

# Resolve an offer externalId to its product durable ID (e.g., "product/<GUID>")
pc_get_product_durable_id() {
	_extid="$1"
	_resp="$(pc_api_get "/product" \
		"externalID=${_extid}" \
		"\$version=${PC_PRODUCT_VERSION}")"

	printf '%s' "$_resp" | jq -e . >/dev/null 2>&1 \
		|| pc_die "Non-JSON response querying product by externalID"

	_durable="$(printf '%s' "$_resp" | jq -r '
		if has("value") then (.value[0].id // empty) else (.id // empty) end
	')"
	[ -n "$_durable" ] || pc_die "Could not resolve product durable ID for externalID=$_extid"
	printf '%s' "$_durable"
}

# Fetch a resource tree for a product
# Usage: pc_get_resource_tree DURABLE_ID TARGET_TYPE
pc_get_resource_tree() {
	_durable="$1"
	_target="${2:-draft}"
	pc_api_get "/resource-tree/${_durable}" \
		"targetType=${_target}" \
		"\$version=${PC_TREE_VERSION}"
}

# POST to /configure endpoint, return the full response JSON
pc_configure() {
	_body="$1"
	pc_api_post \
		"${PC_GRAPH_BASE}/configure?\$version=${PC_CONFIGURE_VERSION}" \
		"$_body"
}

# Poll a configure job until completion
# Usage: pc_poll_job JOB_ID [INTERVAL] [MAX_ATTEMPTS]
# Returns: 0 = succeeded, 1 = failed, 2 = timeout
pc_poll_job() {
	_job_id="$1"
	_interval="${2:-30}"
	_max="${3:-60}"
	_attempt=0

	while [ "$_attempt" -lt "$_max" ]; do
		_status_resp="$(pc_api_get "/configure/${_job_id}/status" \
			"\$version=${PC_CONFIGURE_VERSION}")"
		_job_status="$(printf '%s' "$_status_resp" | jq -r '.jobStatus // empty')"

		case "$_job_status" in
		completed)
			_job_result="$(printf '%s' "$_status_resp" | jq -r '.jobResult // empty')"
			if [ "$_job_result" = "succeeded" ]; then
				echo "Job ${_job_id}: succeeded" >&2
				return 0
			else
				echo "Job ${_job_id}: completed with result=${_job_result}" >&2
				return 1
			fi
			;;
		notStarted|running)
			_attempt=$((_attempt + 1))
			echo "Job ${_job_id}: ${_job_status} (attempt ${_attempt}/${_max}, next check in ${_interval}s)" >&2
			sleep "$_interval"
			;;
		*)
			echo "Job ${_job_id}: unexpected status '${_job_status}'" >&2
			return 1
			;;
		esac
	done

	echo "Job ${_job_id}: timed out after ${_max} attempts" >&2
	return 2
}

# Get full job detail (for error messages)
pc_get_job_detail() {
	_job_id="$1"
	pc_api_get "/configure/${_job_id}" \
		"\$version=${PC_CONFIGURE_VERSION}"
}

# List all VM offers (handles pagination)
pc_list_vm_offers() {
	_tmp="$(mktemp)"
	trap 'rm -f "$_tmp"' EXIT INT TERM

	_url="${PC_GRAPH_BASE}/product?type=azureVirtualMachine&\$maxpagesize=${PC_MAX_PAGE_SIZE}&\$version=${PC_PRODUCT_VERSION}"

	while :; do
		_resp="$(pc_api_get_url "$_url")"
		printf '%s' "$_resp" | jq -e . >/dev/null 2>&1 \
			|| pc_die "Non-JSON response from /product"
		printf '%s\n' "$_resp" >> "$_tmp"

		_next="$(printf '%s' "$_resp" | jq -r '."@nextLink" // empty')"
		[ -n "$_next" ] || break
		_url="$_next"
	done

	jq -s 'map(.value // []) | add' "$_tmp"
	rm -f "$_tmp"
}
