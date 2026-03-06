import json
import logging

import azure.functions as func

from shared import (
    PARTITION_KEY,
    build_timeout_message,
    get_expected_variants,
    get_table_client,
    get_timeout_seconds,
    notify_all,
    parse_utc_iso,
    save_batch,
    to_utc_iso,
    utc_now,
)


def main(timer: func.TimerRequest):
    if timer.past_due:
        logging.info("Timer is past due")

    table = get_table_client()
    expected_variants = get_expected_variants()
    timeout_seconds = get_timeout_seconds()
    now = utc_now()

    entities = table.query_entities(f"PartitionKey eq '{PARTITION_KEY}'")

    for entity in entities:
        complete = bool(entity.get("complete", False))
        timeout_notified = bool(entity.get("timeoutNotified", False))
        if complete or timeout_notified:
            continue

        first_seen = entity.get("firstSeenUtc")
        if not first_seen:
            continue

        age = (now - parse_utc_iso(first_seen)).total_seconds()
        if age < timeout_seconds:
            continue

        seen = sorted(set(json.loads(entity.get("variantsJson", "[]"))))
        missing = [v for v in expected_variants if v not in seen]

        version = entity.get("RowKey", "unknown")
        subject, message = build_timeout_message(version, seen, missing, first_seen)
        notify_all(subject, message)

        entity["timeoutNotified"] = True
        entity["timeoutNotifiedUtc"] = to_utc_iso(now)
        save_batch(table, entity)
