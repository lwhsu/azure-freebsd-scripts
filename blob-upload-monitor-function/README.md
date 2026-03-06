# Blob Upload Monitor (FreeBSD Image Set)

This Azure Function app watches `BlobCreated` events and tracks upload status by
FreeBSD image version.

## Active Functions

- `UploadEvent` (`httpTrigger`): receives Event Grid webhook events, updates
  batch state, sends notifications.
- `TimeoutCheck` (`timerTrigger`): periodically checks incomplete batches and
  sends timeout notifications once timeout is reached.

## Event Matching

- Container: `disks` (configurable)
- Prefix: `FreeBSD-` (configurable)
- Suffix: `.vhd` (configurable)

Expected variants (default):
- `amd64-ufs`
- `amd64-zfs`
- `arm64-aarch64-ufs`
- `arm64-aarch64-zfs`

## Notifications

For each version batch:
1. `started`: sent once when the first expected file arrives.
2. `complete`: sent once when all expected variants are uploaded.
3. `timeout`: sent once when timeout window is reached and batch is still
   incomplete.

Channels:
- `ntfy` (enabled by default)
- `matrix` webhook (optional)
- `email` webhook (optional)

## Main Settings

- `TABLE_NAME` (default `ImageUploadBatches`)
- `TIMEOUT_SECONDS` (default `3600`)
- `TIMEOUT_SWEEP_CRON` (default `0 */5 * * * *`)
- `CONTAINER_NAME`
- `FILENAME_PREFIX`
- `FILENAME_SUFFIX`
- `EXPECTED_VARIANTS`
- `NTFY_SERVER`, `NTFY_TOPIC`, `NTFY_TOKEN`
- `MATRIX_WEBHOOK_URL`
- `EMAIL_WEBHOOK_URL`

## Deploy

```sh
./setup-blob-upload-monitor.sh
```

## Test

1. Upload first file of a version:
- expect `started` notification.

2. Upload all expected variants:
- expect `complete` notification.

3. Upload only one variant and wait past timeout:
- expect `timeout` notification.
