# Blob Upload Monitor (FreeBSD Image Set)

This Azure Function app watches `BlobCreated` events and groups uploads by version.

For files matching:
- container: `disks` (configurable)
- prefix: `FreeBSD-` (configurable)
- suffix: `.vhd` (configurable)

it will:
1. mark arrived variants in table storage,
2. notify when all expected variants are uploaded,
3. notify timeout if not completed within 1 hour (configurable).

## Current notification channels

- `ntfy` (enabled by default)
- `matrix` webhook (reserved; optional)
- `email` webhook (reserved; optional)

## Expected variants

Default:
- `amd64-ufs`
- `amd64-zfs`
- `arm64-aarch64-ufs`
- `arm64-aarch64-zfs`

You can change this without code changes using app setting `EXPECTED_VARIANTS`.

## Deploy

From repo root:

```sh
./setup-blob-upload-monitor.sh
```

The deployment script uses values from `config.sh` and these optional env vars:

- `LOCATION` (default: `eastus`)
- `MONITOR_FUNCTION_APP` (default: `freebsd-img-upload-monitor`)
- `MONITOR_STORAGE_ACCOUNT` (default: generated)
- `EVENT_SUBSCRIPTION_NAME` (default: `freebsd-image-upload-created`)
- `TABLE_NAME` (default: `ImageUploadBatches`)
- `CONTAINER_NAME` (default from `STORAGE_ACCOUNT_CONTAINER`)
- `FILENAME_PREFIX` (default: `FreeBSD-`)
- `FILENAME_SUFFIX` (default: `.vhd`)
- `EXPECTED_VARIANTS` (comma-separated)
- `TIMEOUT_SECONDS` (default: `3600`)
- `NTFY_SERVER` (default: `https://ntfy.sh`)
- `NTFY_TOPIC` (default: `freebsd-azure-image-upload`)
- `NTFY_TOKEN` (optional)
- `MATRIX_WEBHOOK_URL` (optional)
- `EMAIL_WEBHOOK_URL` (optional)

## Test

Upload one matching blob and verify no "complete" notification yet.

Upload all expected variants for one version and verify one "complete" notification.

For timeout testing, temporarily set `TIMEOUT_SECONDS=120` and upload only one file.
