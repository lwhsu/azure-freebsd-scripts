# Blob Upload Monitor

## Goal

Automate FreeBSD image upload monitoring in Azure Blob Storage and stop manual
polling.

Required behavior:
- send a notification when upload starts (first file arrives),
- send a notification when a full image set is complete,
- send a timeout warning if still incomplete after timeout window.

## File Pattern

- Container: `disks`
- Prefix: `FreeBSD-`
- Suffix: `.vhd`

One version batch example (`14.4-RC1`):
- `FreeBSD-14.4-RC1-amd64-ufs.vhd`
- `FreeBSD-14.4-RC1-amd64-zfs.vhd`
- `FreeBSD-14.4-RC1-arm64-aarch64-ufs.vhd`
- `FreeBSD-14.4-RC1-arm64-aarch64-zfs.vhd`

## Current Architecture

1. Event Grid subscription forwards `Microsoft.Storage.BlobCreated` events to
   `UploadEvent` webhook endpoint.
2. `UploadEvent` parses `(version, variant)`, updates table state, and sends:
- `started` once for first blob,
- `complete` once when all expected variants are present.
3. `TimeoutCheck` timer trigger runs by cron and scans table state:
- if `age >= TIMEOUT_SECONDS` and still incomplete, sends `timeout` once.

## State Model

Table (default): `ImageUploadBatches`

Entity key:
- `PartitionKey = freebsd-image-upload`
- `RowKey = <version>`

Main fields:
- `firstSeenUtc`, `lastSeenUtc`
- `variantsJson`, `expectedVariantsJson`
- `startedNotified`, `startedNotifiedUtc`
- `complete`, `completionNotified`, `completedUtc`, `completionNotifiedUtc`
- `timeoutNotified`, `timeoutNotifiedUtc`

## Deployment Script

`setup-blob-upload-monitor.sh` does:
1. create/update monitor storage account,
2. ensure state table exists,
3. create/update function app and app settings,
4. deploy function package,
5. sync triggers and validate required functions exist,
6. create/replace Event Grid subscription endpoint.

## Current Runtime Notes

- `UploadEvent` uses `httpTrigger` and handles Event Grid
  `SubscriptionValidation` handshake.
- `TimeoutCheck` uses `timerTrigger` with `TIMEOUT_SWEEP_CRON`.
- Existing app had remote-build instability; fallback deployment paths may be
  needed during operations.

## Configuration

Core:
- `MONITOR_FUNCTION_APP`
- `MONITOR_STORAGE_ACCOUNT`
- `EVENT_SUBSCRIPTION_NAME`
- `TABLE_NAME`

Matching:
- `CONTAINER_NAME`
- `FILENAME_PREFIX`
- `FILENAME_SUFFIX`
- `EXPECTED_VARIANTS`

Timeout:
- `TIMEOUT_SECONDS`
- `TIMEOUT_SWEEP_CRON`

Notification:
- `NTFY_SERVER`, `NTFY_TOPIC`, `NTFY_TOKEN`
- `MATRIX_WEBHOOK_URL`
- `EMAIL_WEBHOOK_URL`

## Validation Checklist

1. First file uploaded -> row exists and `startedNotified=true`.
2. All four variants uploaded -> `complete=true`, `completionNotified=true`.
3. Incomplete batch past timeout -> `timeoutNotified=true`.

## Collaboration Rule

Keep this document in sync with code changes in the same commit.
