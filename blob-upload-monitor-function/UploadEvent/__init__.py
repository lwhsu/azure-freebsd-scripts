import json
import logging
import os

import azure.functions as func

from shared import (
    build_completed_message,
    get_expected_variants,
    get_table_client,
    load_batch,
    notify_all,
    parse_blob_name_from_subject,
    parse_version_and_variant,
    save_batch,
    to_utc_iso,
    utc_now,
)


def main(event: func.EventGridEvent):
    expected_variants = get_expected_variants()
    table = get_table_client()

    container_name = os.getenv("CONTAINER_NAME", "disks")
    prefix = os.getenv("FILENAME_PREFIX", "FreeBSD-")
    suffix = os.getenv("FILENAME_SUFFIX", ".vhd")

    payload = event.get_json()
    if not isinstance(payload, dict):
        payload = json.loads(json.dumps(payload))

    parsed = parse_blob_name_from_subject(event.subject)
    if not parsed:
        logging.info("Skip event: unsupported subject format: %s", event.subject)
        return

    container, blob_name = parsed
    if container != container_name:
        logging.info("Skip event: container mismatch (%s)", container)
        return

    result = parse_version_and_variant(blob_name, prefix, suffix, expected_variants)
    if not result:
        logging.info("Skip event: filename not matched (%s)", blob_name)
        return

    version, variant = result
    now_iso = to_utc_iso(utc_now())

    entity = load_batch(table, version, expected_variants)
    seen = set(json.loads(entity.get("variantsJson", "[]")))
    seen.add(variant)

    entity["variantsJson"] = json.dumps(sorted(seen))
    entity["lastSeenUtc"] = now_iso

    completed = all(v in seen for v in expected_variants)
    entity["complete"] = completed

    blob_url = payload.get("url") or payload.get("data", {}).get("url") or ""

    if completed and not entity.get("completionNotified", False):
        entity["completedUtc"] = now_iso
        entity["completionNotified"] = True
        entity["completionNotifiedUtc"] = now_iso

        subject, message = build_completed_message(version, sorted(seen), blob_url)
        notify_all(subject, message)

    save_batch(table, entity)
