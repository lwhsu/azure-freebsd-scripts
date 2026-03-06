#!/bin/sh

set -eu

. ./config.sh
. ./subr.sh

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
	--kind StorageV2

MONITOR_STORAGE_KEY="$(az storage account keys list \
	--resource-group "${RESOURCE_GROUP}" \
	--account-name "${MONITOR_STORAGE_ACCOUNT}" \
	--query '[0].value' -o tsv)"

MONITOR_STORAGE_CONN="$(az storage account show-connection-string \
	--resource-group "${RESOURCE_GROUP}" \
	--name "${MONITOR_STORAGE_ACCOUNT}" \
	--key "${MONITOR_STORAGE_KEY}" \
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
	--functions-version 4 \
	--runtime python \
	--runtime-version 3.11

echo "Set function app settings"
az functionapp config appsettings set \
	--name "${MONITOR_FUNCTION_APP}" \
	--resource-group "${RESOURCE_GROUP}" \
	--settings \
	STATE_STORAGE_CONNECTION_STRING="${MONITOR_STORAGE_CONN}" \
	TABLE_NAME="${TABLE_NAME}" \
	CONTAINER_NAME="${CONTAINER_NAME}" \
	FILENAME_PREFIX="${FILENAME_PREFIX}" \
	FILENAME_SUFFIX="${FILENAME_SUFFIX}" \
	EXPECTED_VARIANTS="${EXPECTED_VARIANTS}" \
	TIMEOUT_SECONDS="${TIMEOUT_SECONDS}" \
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

echo "Deploy function code"
az functionapp deployment source config-zip \
	--name "${MONITOR_FUNCTION_APP}" \
	--resource-group "${RESOURCE_GROUP}" \
	--src "${FUNC_ZIP}"

SOURCE_ID="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT_NAME}"
ENDPOINT_ID="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${MONITOR_FUNCTION_APP}/functions/UploadEvent"

echo "Create/replace event subscription: ${EVENT_SUBSCRIPTION_NAME}"
if az eventgrid event-subscription show --name "${EVENT_SUBSCRIPTION_NAME}" --source-resource-id "${SOURCE_ID}" >/dev/null 2>&1; then
	az eventgrid event-subscription delete --name "${EVENT_SUBSCRIPTION_NAME}" --source-resource-id "${SOURCE_ID}"
fi

az eventgrid event-subscription create \
	--name "${EVENT_SUBSCRIPTION_NAME}" \
	--source-resource-id "${SOURCE_ID}" \
	--endpoint-type azurefunction \
	--endpoint "${ENDPOINT_ID}" \
	--included-event-types Microsoft.Storage.BlobCreated \
	--subject-begins-with "/blobServices/default/containers/${CONTAINER_NAME}/blobs/${FILENAME_PREFIX}" \
	--subject-ends-with "${FILENAME_SUFFIX}"

echo
echo "Deployment finished."
echo "Function app: ${MONITOR_FUNCTION_APP}"
echo "Event subscription: ${EVENT_SUBSCRIPTION_NAME}"
echo "ntfy topic: ${NTFY_SERVER}/${NTFY_TOPIC}"
