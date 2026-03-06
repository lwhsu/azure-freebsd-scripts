# Blob Upload Monitor

## Goal

Build an automated monitor for FreeBSD image uploads in Azure Blob Storage so we do not need to run manual listing scripts repeatedly.

Primary objective:
- Notify when a full image set for one version is uploaded.

Additional objective:
- Notify if a set is still incomplete 1 hour after the first file appears.

Current target naming pattern:
- Prefix: `FreeBSD-`
- Suffix: `.vhd`
- Container: `disks`
- Example version token: `14.4-RC1`

Current expected variants per version:
- `amd64-ufs`
- `amd64-zfs`
- `arm64-aarch64-ufs`
- `arm64-aarch64-zfs`

Important: expected variants are configurable to support future expansion.

## Scope and Constraints

- Source storage account and container come from repository config conventions (`config.sh`).
- Event source is Azure Storage `BlobCreated` events.
- Notification channel starts with `ntfy` and is designed to expand to Matrix and email.
- The system should avoid duplicate notifications for the same completion/timeout condition.

## Architecture

1. Azure Storage Account emits `Microsoft.Storage.BlobCreated` events.
2. Event Grid filters events by subject:
   - container path begins with `/blobServices/default/containers/disks/blobs/FreeBSD-`
   - subject ends with `.vhd`
3. Event Grid sends matching events to Azure Function `UploadEvent`.
4. `UploadEvent` parses version + variant and updates batch state in Table Storage.
5. If all expected variants are present, send a completion notification.
6. Timer-triggered Azure Function `TimeoutSweep` runs every 5 minutes.
7. `TimeoutSweep` checks incomplete batches and sends timeout notifications after 1 hour.

## Repository Layout

- Deployment script:
  - `setup-blob-upload-monitor.sh`
- Function app source:
  - `blob-upload-monitor-function/host.json`
  - `blob-upload-monitor-function/requirements.txt`
  - `blob-upload-monitor-function/shared.py`
  - `blob-upload-monitor-function/UploadEvent/function.json`
  - `blob-upload-monitor-function/UploadEvent/__init__.py`
  - `blob-upload-monitor-function/TimeoutSweep/function.json`
  - `blob-upload-monitor-function/TimeoutSweep/__init__.py`
  - `blob-upload-monitor-function/README.md`

## State Model (Table Storage)

Table name defaults to `ImageUploadBatches`.

Partition key:
- `freebsd-image-upload`

Row key:
- version token (example: `14.4-RC1`)

Main fields:
- `firstSeenUtc`
- `lastSeenUtc`
- `variantsJson`
- `expectedVariantsJson`
- `complete`
- `completionNotified`
- `timeoutNotified`
- `completedUtc` (when completed)
- `completionNotifiedUtc` (when completion alert sent)
- `timeoutNotifiedUtc` (when timeout alert sent)

## Notification Strategy

Current enabled channel:
- ntfy (`NTFY_SERVER`, `NTFY_TOPIC`, optional `NTFY_TOKEN`)

Reserved extension points:
- Matrix webhook (`MATRIX_WEBHOOK_URL`)
- Email webhook (`EMAIL_WEBHOOK_URL`)

Design principle:
- Business logic (batch tracking) is independent from transport (notification channel).

## Deployment

Prerequisites:
- Azure CLI authenticated to target subscription.
- `zip` command installed.
- `config.sh` contains valid values for:
  - `SUBSCRIPTION`
  - `RESOURCE_GROUP`
  - `STORAGE_ACCOUNT_NAME`
  - `STORAGE_ACCOUNT_CONTAINER`

Run:

```sh
NTFY_SERVER=https://ntfy.sh \
NTFY_TOPIC=freebsd-azure-image-upload \
./setup-blob-upload-monitor.sh
```

What the script does:
1. Creates a storage account for function/state storage.
2. Creates state table.
3. Creates Function App (Python 3.11, Functions v4).
4. Sets app settings (filters, variants, timeout, notification config).
5. Packages/deploys function code as zip.
6. Creates/recreates Event Grid subscription from source storage account.

## Configuration

Environment variables used by deployment/runtime:

Core:
- `LOCATION` (default: `eastus`)
- `MONITOR_FUNCTION_APP`
- `MONITOR_STORAGE_ACCOUNT`
- `EVENT_SUBSCRIPTION_NAME`
- `TABLE_NAME` (default: `ImageUploadBatches`)

Filtering and matching:
- `CONTAINER_NAME` (default from `STORAGE_ACCOUNT_CONTAINER`)
- `FILENAME_PREFIX` (default: `FreeBSD-`)
- `FILENAME_SUFFIX` (default: `.vhd`)
- `EXPECTED_VARIANTS` (comma-separated)

Timeout:
- `TIMEOUT_SECONDS` (default: `3600`)
- `VM_POLL_*` is unrelated and belongs to VM scripts (not this monitor)

Notification:
- `NTFY_SERVER`
- `NTFY_TOPIC`
- `NTFY_TOKEN` (optional)
- `MATRIX_WEBHOOK_URL` (optional)
- `EMAIL_WEBHOOK_URL` (optional)

## Operational Behavior

Completion path:
- Files for one version arrive in any order.
- When all expected variants are seen, monitor sends one completion notification.

Timeout path:
- If first file arrived and batch is still incomplete after timeout window, send one timeout notification.

Idempotency:
- Completion and timeout notifications are separately flagged in state to avoid duplicates.

## Testing Plan

1. Positive completion test:
- Upload all expected variants for a test version.
- Confirm one completion notification.

2. Timeout test:
- Temporarily set `TIMEOUT_SECONDS=120`.
- Upload only one variant.
- Confirm timeout notification after ~2+ minutes.

3. Filter test:
- Upload a non-matching blob name.
- Confirm no notification and no state entry.

4. Duplicate event resilience:
- Re-upload or trigger repeated events for same blob.
- Confirm no duplicate completion/timeout alerts.

## Known Risks / Follow-up

- Azure CLI environment on this host currently shows missing Python module issues for some appservice commands (`az functionapp create` may fail until fixed).
- Public ntfy topics may expose metadata; move to authenticated/self-hosted channel when needed.
- Matrix and final email provider integration are placeholders pending final transport decision.

## Collaboration Workflow

This file is the shared source of truth for this feature.

When implementation changes, update this document in the same PR/commit, including:
- architecture changes,
- config or deployment changes,
- runbook and test updates,
- known issues and mitigation.

