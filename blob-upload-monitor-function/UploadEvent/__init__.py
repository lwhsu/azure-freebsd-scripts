import json
import logging
import os
import traceback

import azure.functions as func

from shared import (
    build_completed_message,
    build_started_message,
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


def _iter_events(req: func.HttpRequest):
    try:
        body = req.get_json()
    except ValueError:
        body = None

    if isinstance(body, list):
        return body
    if isinstance(body, dict):
        return [body]
    return []


def main(req: func.HttpRequest) -> func.HttpResponse:
    try:
        aeg_event_type = (req.headers.get("aeg-event-type") or "").strip().lower()
        events = _iter_events(req)

        if aeg_event_type == "subscriptionvalidation" and events:
            code = events[0].get("data", {}).get("validationCode", "")
            return func.HttpResponse(
                json.dumps({"validationResponse": code}),
                status_code=200,
                mimetype="application/json",
            )

        expected_variants = get_expected_variants()
        table = get_table_client()

        container_name = os.getenv("CONTAINER_NAME", "disks")
        prefix = os.getenv("FILENAME_PREFIX", "FreeBSD-")
        suffix = os.getenv("FILENAME_SUFFIX", ".vhd")

        for ev in events:
            subject = ev.get("subject", "")
            parsed = parse_blob_name_from_subject(subject)
            if not parsed:
                logging.info("Skip event: unsupported subject format: %s", subject)
                continue

            container, blob_name = parsed
            if container != container_name:
                logging.info("Skip event: container mismatch (%s)", container)
                continue

            result = parse_version_and_variant(blob_name, prefix, suffix, expected_variants)
            if not result:
                logging.info("Skip event: filename not matched (%s)", blob_name)
                continue

            version, variant = result
            now_iso = to_utc_iso(utc_now())

            entity = load_batch(table, version, expected_variants)
            seen = set(json.loads(entity.get("variantsJson", "[]")))
            is_first_blob = len(seen) == 0
            seen.add(variant)

            entity["variantsJson"] = json.dumps(sorted(seen))
            entity["lastSeenUtc"] = now_iso

            completed = all(v in seen for v in expected_variants)
            entity["complete"] = completed

            payload = ev.get("data", {})
            blob_url = payload.get("url", "")

            if is_first_blob and not entity.get("startedNotified", False):
                entity["startedNotified"] = True
                entity["startedNotifiedUtc"] = now_iso

                subject_msg, message = build_started_message(version, variant, blob_url)
                notify_all(subject_msg, message)

            if completed and not entity.get("completionNotified", False):
                entity["completedUtc"] = now_iso
                entity["completionNotified"] = True
                entity["completionNotifiedUtc"] = now_iso

                subject_msg, message = build_completed_message(version, sorted(seen), blob_url)
                notify_all(subject_msg, message)

            save_batch(table, entity)

        return func.HttpResponse(status_code=200)
    except Exception:
        return func.HttpResponse(traceback.format_exc(), status_code=500, mimetype="text/plain")
