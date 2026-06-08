#!/usr/bin/env python3
"""Append one flexible JSON object to a JSONL file.

This helper is intentionally stdlib-only so audit agents can record structured
notes without hand-formatting JSON. It validates the final record is an object,
creates the output directory, appends exactly one line, and prints the line it
wrote so the caller can include it in a durable Stako result.
"""

import argparse
import datetime
import json
import os
import sys


def parse_value(text):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def parse_field(text):
    if "=" not in text:
        raise argparse.ArgumentTypeError("expected key=value, got {!r}".format(text))
    key, value = text.split("=", 1)
    key = key.strip()
    if not key:
        raise argparse.ArgumentTypeError("field key cannot be empty")
    return key, parse_value(value)


def merge_record(record, obj):
    for key, value in obj.items():
        record[key] = value


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", required=True, help="JSONL file to append")
    parser.add_argument("--kind", help="record kind, e.g. entrypoint, trace, allocation")
    parser.add_argument("--id", help="stable record id")
    parser.add_argument("--field", action="append", type=parse_field, default=[])
    parser.add_argument("--note", action="append", default=[])
    parser.add_argument("--json", action="append", default=[], help="JSON object to merge")
    parser.add_argument("--dry-run", action="store_true", help="print without appending")
    args = parser.parse_args(argv)

    record = {
        "schema_version": 1,
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    if args.kind:
        record["kind"] = args.kind
    if args.id:
        record["id"] = args.id

    for raw in args.json:
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError as exc:
            parser.error("--json is not valid JSON: {}".format(exc))
        if not isinstance(obj, dict):
            parser.error("--json must decode to an object")
        merge_record(record, obj)

    for key, value in args.field:
        record[key] = value

    if args.note:
        record["notes"] = args.note if len(args.note) > 1 else args.note[0]

    line = json.dumps(record, sort_keys=True, separators=(",", ":"))
    if not args.dry_run:
        parent = os.path.dirname(os.path.abspath(args.path))
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(args.path, "a", encoding="utf-8") as fh:
            fh.write(line)
            fh.write("\n")
    print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
