#!/bin/sh

set -eu

OVERRIDE_VARS="
SUBSCRIPTION
RESOURCE_GROUP
STORAGE_ACCOUNT_NAME
STORAGE_ACCOUNT_CONTAINER
LOCATION
MONITOR_FUNCTION_APP
MONITOR_STORAGE_ACCOUNT
EVENT_SUBSCRIPTION_NAME
TABLE_NAME
CONTAINER_NAME
FILENAME_PREFIX
FILENAME_SUFFIX
EXPECTED_VARIANTS
TIMEOUT_SECONDS
TIMEOUT_SWEEP_CRON
NTFY_SERVER
NTFY_TOPIC
NTFY_TOKEN
MATRIX_WEBHOOK_URL
EMAIL_WEBHOOK_URL
"

for v in ${OVERRIDE_VARS}; do
	eval "_SET_${v}=\${${v}+x}"
	eval "_OVR_${v}=\${${v}-}"
done

. ./config.sh
. ./subr.sh

for v in ${OVERRIDE_VARS}; do
	eval "_set=\${_SET_${v}}"
	if [ "${_set}" = "x" ]; then
		eval "${v}=\${_OVR_${v}}"
	fi
done

require SUBSCRIPTION
require RESOURCE_GROUP
require STORAGE_ACCOUNT_NAME
require STORAGE_ACCOUNT_CONTAINER

LOCATION="${LOCATION:-eastus}"

MONITOR_FUNCTION_APP="${MONITOR_FUNCTION_APP:-freebsd-img-upload-monitor}"
MONITOR_STORAGE_ACCOUNT="${MONITOR_STORAGE_ACCOUNT:-fbimgmon$(date +%m%d%H%M)}"
EVENT_SUBSCRIPTION_NAME="${EVENT_SUBSCRIPTION_NAME:-freebsd-image-upload-created}"
TABLE_NAME="${TABLE_NAME:-ImageUploadBatches}"

CONTAINER_NAME="${CONTAINER_NAME:-${STORAGE_ACCOUNT_CONTAINER}}"
FILENAME_PREFIX="${FILENAME_PREFIX:-FreeBSD-}"
FILENAME_SUFFIX="${FILENAME_SUFFIX:-.vhd}"
EXPECTED_VARIANTS="${EXPECTED_VARIANTS:-amd64-ufs,amd64-zfs,arm64-aarch64-ufs,arm64-aarch64-zfs}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-3600}"
TIMEOUT_SWEEP_CRON="${TIMEOUT_SWEEP_CRON:-0 */5 * * * *}"

NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-freebsd-azure-image-upload}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
MATRIX_WEBHOOK_URL="${MATRIX_WEBHOOK_URL:-}"
EMAIL_WEBHOOK_URL="${EMAIL_WEBHOOK_URL:-}"

FUNC_SRC_DIR="blob-upload-monitor-function"
FUNC_ZIP="/tmp/blob-upload-monitor-function.zip"

if ! command -v zip >/dev/null 2>&1; then
	echo "zip is required" >&2
	exit 1
fi

az account set --subscription "${SUBSCRIPTION}"

echo "Create monitor storage account: ${MONITOR_STORAGE_ACCOUNT}"
az storage account create \
	--name "${MONITOR_STORAGE_ACCOUNT}" \
	--resource-group "${RESOURCE_GROUP}" \
	--location "${LOCATION}" \
	--sku Standard_LRS \
	--kind StorageV2 \
	--min-tls-version TLS1_2

MONITOR_STORAGE_KEY="$(az storage account keys list \
	--resource-group "${RESOURCE_GROUP}" \
	--account-name "${MONITOR_STORAGE_ACCOUNT}" \
	--query '[0].value' -o tsv)"

MONITOR_STORAGE_CONN="$(az storage account show-connection-string \
	--resource-group "${RESOURCE_GROUP}" \
	--name "${MONITOR_STORAGE_ACCOUNT}" \
	--query connectionString -o tsv)"

echo "Create state table: ${TABLE_NAME}"
az storage table create \
	--name "${TABLE_NAME}" \
	--account-name "${MONITOR_STORAGE_ACCOUNT}" \
	--account-key "${MONITOR_STORAGE_KEY}"

echo "Create function app: ${MONITOR_FUNCTION_APP}"
az functionapp create \
	--name "${MONITOR_FUNCTION_APP}" \
	--resource-group "${RESOURCE_GROUP}" \
	--consumption-plan-location "${LOCATION}" \
	--storage-account "${MONITOR_STORAGE_ACCOUNT}" \
	--os-type Linux \
	--functions-version 4 \
	--runtime python \
	--runtime-version 3.11

echo "Set function app settings"
az functionapp config appsettings set \
	--name "${MONITOR_FUNCTION_APP}" \
	--resource-group "${RESOURCE_GROUP}" \
	--settings \
	SCM_DO_BUILD_DURING_DEPLOYMENT=true \
	ENABLE_ORYX_BUILD=true \
	STATE_STORAGE_CONNECTION_STRING="${MONITOR_STORAGE_CONN}" \
	TABLE_NAME="${TABLE_NAME}" \
	CONTAINER_NAME="${CONTAINER_NAME}" \
	FILENAME_PREFIX="${FILENAME_PREFIX}" \
	FILENAME_SUFFIX="${FILENAME_SUFFIX}" \
	EXPECTED_VARIANTS="${EXPECTED_VARIANTS}" \
	TIMEOUT_SECONDS="${TIMEOUT_SECONDS}" \
	TIMEOUT_SWEEP_CRON="${TIMEOUT_SWEEP_CRON}" \
	NTFY_SERVER="${NTFY_SERVER}" \
	NTFY_TOPIC="${NTFY_TOPIC}" \
	NTFY_TOKEN="${NTFY_TOKEN}" \
	MATRIX_WEBHOOK_URL="${MATRIX_WEBHOOK_URL}" \
	EMAIL_WEBHOOK_URL="${EMAIL_WEBHOOK_URL}"

echo "Package function source"
rm -f "${FUNC_ZIP}"
(
	cd "${FUNC_SRC_DIR}"
	zip -q -r "${FUNC_ZIP}" .
)

echo "Deploy function code (remote build)"
az functionapp deployment source config-zip \
	--name "${MONITOR_FUNCTION_APP}" \
	--resource-group "${RESOURCE_GROUP}" \
	--src "${FUNC_ZIP}" \
	--build-remote true \
	--timeout 1200

az rest --method post \
	--url "https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${MONITOR_FUNCTION_APP}/syncfunctiontriggers?api-version=2022-03-01" \
	-o none

FUNCTIONS="$(az functionapp function list --resource-group "${RESOURCE_GROUP}" --name "${MONITOR_FUNCTION_APP}" --query '[].name' -o tsv)"
printf '%s\n' "${FUNCTIONS}" | grep -q '/UploadEvent$' || {
	echo "UploadEvent function not indexed after deployment." >&2
	exit 1
}
printf '%s\n' "${FUNCTIONS}" | grep -q '/TimeoutCheck$' || {
	echo "TimeoutCheck function not indexed after deployment." >&2
	exit 1
}

EVENT_FUNCTION_KEY="$(az functionapp function keys list \
	--resource-group "${RESOURCE_GROUP}" \
	--name "${MONITOR_FUNCTION_APP}" \
	--function-name UploadEvent \
	--query default -o tsv)"

SOURCE_ID="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT_NAME}"
ENDPOINT_URL="https://${MONITOR_FUNCTION_APP}.azurewebsites.net/api/uploadevent?code=${EVENT_FUNCTION_KEY}"

echo "Create/replace event subscription: ${EVENT_SUBSCRIPTION_NAME}"
if az eventgrid event-subscription show --name "${EVENT_SUBSCRIPTION_NAME}" --source-resource-id "${SOURCE_ID}" >/dev/null 2>&1; then
	az eventgrid event-subscription delete --name "${EVENT_SUBSCRIPTION_NAME}" --source-resource-id "${SOURCE_ID}"
fi

az eventgrid event-subscription create \
	--name "${EVENT_SUBSCRIPTION_NAME}" \
	--source-resource-id "${SOURCE_ID}" \
	--endpoint "${ENDPOINT_URL}" \
	--included-event-types Microsoft.Storage.BlobCreated \
	--subject-begins-with "/blobServices/default/containers/${CONTAINER_NAME}/blobs/${FILENAME_PREFIX}" \
	--subject-ends-with "${FILENAME_SUFFIX}"

echo
echo "Deployment finished."
echo "Function app: ${MONITOR_FUNCTION_APP}"
echo "Source storage account: ${STORAGE_ACCOUNT_NAME}"
echo "Event subscription: ${EVENT_SUBSCRIPTION_NAME}"
echo "ntfy topic: ${NTFY_SERVER}/${NTFY_TOPIC}"
