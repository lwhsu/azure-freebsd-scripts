import json
import logging
import os
import re
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple
from urllib import request

from azure.data.tables import TableServiceClient

PARTITION_KEY = "freebsd-image-upload"


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def to_utc_iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_utc_iso(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def get_expected_variants() -> List[str]:
    value = os.getenv(
        "EXPECTED_VARIANTS",
        "amd64-ufs,amd64-zfs,arm64-aarch64-ufs,arm64-aarch64-zfs",
    )
    return [x.strip() for x in value.split(",") if x.strip()]


def get_table_name() -> str:
    return os.getenv("TABLE_NAME", "ImageUploadBatches")


def get_timeout_seconds() -> int:
    return int(os.getenv("TIMEOUT_SECONDS", "3600"))


def get_storage_connection_string() -> str:
    conn = os.getenv("STATE_STORAGE_CONNECTION_STRING") or os.getenv("AzureWebJobsStorage")
    if not conn:
        raise RuntimeError("STATE_STORAGE_CONNECTION_STRING or AzureWebJobsStorage is required")
    return conn


def get_table_client():
    service = TableServiceClient.from_connection_string(get_storage_connection_string())
    table_name = get_table_name()
    table = service.get_table_client(table_name=table_name)
    table.create_table()
    return table


def parse_blob_name_from_subject(subject: str) -> Optional[Tuple[str, str]]:
    pattern = r"^/blobServices/default/containers/([^/]+)/blobs/(.+)$"
    m = re.match(pattern, subject)
    if not m:
        return None
    return m.group(1), m.group(2)


def parse_version_and_variant(blob_name: str, prefix: str, suffix: str, variants: List[str]) -> Optional[Tuple[str, str]]:
    if not blob_name.startswith(prefix) or not blob_name.endswith(suffix):
        return None

    core = blob_name[len(prefix) : len(blob_name) - len(suffix)]
    for variant in variants:
        marker = f"-{variant}"
        if core.endswith(marker):
            version = core[: -len(marker)]
            if version:
                return version, variant
    return None


def load_batch(table, version: str, expected_variants: List[str]) -> Dict:
    try:
        entity = table.get_entity(partition_key=PARTITION_KEY, row_key=version)
    except Exception:
        now_iso = to_utc_iso(utc_now())
        entity = {
            "PartitionKey": PARTITION_KEY,
            "RowKey": version,
            "firstSeenUtc": now_iso,
            "lastSeenUtc": now_iso,
            "variantsJson": "[]",
            "expectedVariantsJson": json.dumps(expected_variants),
            "complete": False,
            "completionNotified": False,
            "timeoutNotified": False,
        }
    return entity


def save_batch(table, entity: Dict) -> None:
    table.upsert_entity(mode="Merge", entity=entity)


def notify_ntfy(subject: str, message: str) -> None:
    server = os.getenv("NTFY_SERVER", "https://ntfy.sh").rstrip("/")
    topic = os.getenv("NTFY_TOPIC")
    if not topic:
        logging.info("NTFY_TOPIC not configured; skip ntfy notification")
        return

    url = f"{server}/{topic}"
    token = os.getenv("NTFY_TOKEN", "")

    req = request.Request(url, data=message.encode("utf-8"), method="POST")
    req.add_header("Title", subject)
    req.add_header("Priority", "default")
    req.add_header("Tags", "azure,blob,freebsd")
    if token:
        req.add_header("Authorization", f"Bearer {token}")

    with request.urlopen(req, timeout=20):
        pass


def notify_webhook(env_name: str, subject: str, message: str) -> None:
    url = os.getenv(env_name, "").strip()
    if not url:
        return

    payload = {"subject": subject, "message": message}
    data = json.dumps(payload).encode("utf-8")
    req = request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")

    with request.urlopen(req, timeout=20):
        pass


def notify_all(subject: str, message: str) -> None:
    notify_ntfy(subject, message)

    # Reserved integration points for future channels.
    notify_webhook("MATRIX_WEBHOOK_URL", subject, message)
    notify_webhook("EMAIL_WEBHOOK_URL", subject, message)


def build_completed_message(version: str, variants: List[str], blob_url: str) -> Tuple[str, str]:
    subject = f"FreeBSD image upload complete: {version}"
    lines = [
        f"Version: {version}",
        "Status: 4/4 uploads completed",
        "Variants:",
    ]
    lines.extend([f"- {v}" for v in sorted(variants)])
    lines.append(f"Sample blob URL: {blob_url}")
    return subject, "\n".join(lines)


def build_timeout_message(version: str, seen: List[str], missing: List[str], first_seen: str) -> Tuple[str, str]:
    subject = f"FreeBSD image upload timeout: {version}"
    lines = [
        f"Version: {version}",
        f"First seen: {first_seen}",
        "Status: not all expected blobs uploaded within timeout",
        "Seen variants:",
    ]
    lines.extend([f"- {v}" for v in sorted(seen)])
    lines.append("Missing variants:")
    lines.extend([f"- {v}" for v in sorted(missing)])
    return subject, "\n".join(lines)
