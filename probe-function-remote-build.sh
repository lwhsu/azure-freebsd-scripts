#!/bin/sh

set -eu

. ./config.sh
. ./subr.sh

MONITOR_FUNCTION_APP="${MONITOR_FUNCTION_APP:-freebsd-img-upload-monitor}"
RESOURCE_GROUP="${RESOURCE_GROUP:-FreeBSD}"
SUBSCRIPTION="${SUBSCRIPTION:-}"

require RESOURCE_GROUP
require MONITOR_FUNCTION_APP

if [ -n "${SUBSCRIPTION}" ]; then
	az account set --subscription "${SUBSCRIPTION}"
fi

echo "=== Function App ==="
echo "resource_group: ${RESOURCE_GROUP}"
echo "function_app:   ${MONITOR_FUNCTION_APP}"

echo

echo "=== Host Status ==="
MASTER_KEY="$(az functionapp keys list \
	--resource-group "${RESOURCE_GROUP}" \
	--name "${MONITOR_FUNCTION_APP}" \
	--query masterKey -o tsv)"

curl -sS \
	-H "x-functions-key: ${MASTER_KEY}" \
	"https://${MONITOR_FUNCTION_APP}.azurewebsites.net/admin/host/status"

echo

echo

echo "=== Indexed Functions ==="
az functionapp function list \
	--resource-group "${RESOURCE_GROUP}" \
	--name "${MONITOR_FUNCTION_APP}" \
	--query "[].name" -o tsv

echo

echo "=== App Settings (selected) ==="
az functionapp config appsettings list \
	--resource-group "${RESOURCE_GROUP}" \
	--name "${MONITOR_FUNCTION_APP}" \
	--query "[?name=='SCM_DO_BUILD_DURING_DEPLOYMENT' || name=='ENABLE_ORYX_BUILD' || name=='WEBSITE_RUN_FROM_PACKAGE' || name=='FUNCTIONS_WORKER_RUNTIME' || name=='FUNCTIONS_EXTENSION_VERSION' || name=='SOURCE_STORAGE_CONNECTION_STRING' || name=='STATE_STORAGE_CONNECTION_STRING' || name=='CONTAINER_NAME' || name=='TIMEOUT_QUEUE_NAME' || name=='TABLE_NAME'].{name:name,slotSetting:slotSetting}" \
	-o table

echo

echo "=== Latest Deployments (ARM) ==="
az rest --method get \
	--url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${MONITOR_FUNCTION_APP}/deployments?api-version=2023-12-01" \
	--query "value[0:5].{id:name,status:properties.status,start:properties.start_time,end:properties.end_time,message:properties.message,logUrl:properties.log_url}" \
	-o table

echo

echo "=== Kudu Latest Deployment Log (best effort) ==="
SCM_URI="$(az webapp deployment list-publishing-credentials \
	--resource-group "${RESOURCE_GROUP}" \
	--name "${MONITOR_FUNCTION_APP}" \
	--query scmUri -o tsv)"

python3 - <<'PY'
import os
import subprocess
import urllib.parse
import urllib.request
import base64
import json

scm_uri = subprocess.check_output([
    'az','webapp','deployment','list-publishing-credentials',
    '--resource-group', os.environ['RESOURCE_GROUP'],
    '--name', os.environ['MONITOR_FUNCTION_APP'],
    '--query','scmUri','-o','tsv'
], text=True).strip()

u = urllib.parse.urlparse(scm_uri)
if not u.username or not u.password:
    print('No SCM basic auth in scmUri; cannot fetch Kudu logs.')
    raise SystemExit(0)

user = urllib.parse.unquote(u.username)
pwd = urllib.parse.unquote(u.password)
auth = base64.b64encode(f"{user}:{pwd}".encode()).decode()
base = f"https://{u.hostname}"

for path in [
    '/api/deployments',
    '/api/deployments/latest',
    '/api/deployments/latest/log'
]:
    print(f'--- {path} ---')
    req = urllib.request.Request(base + path)
    req.add_header('Authorization', 'Basic ' + auth)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read().decode('utf-8', 'replace')
            print(body[:4000])
    except Exception as e:
        print(f'ERR: {e}')
PY
