#!/usr/bin/env python3
"""Create deterministic JSON/Markdown summaries from Suricata EVE JSON."""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import ipaddress
import json
import sys
from pathlib import Path
from typing import Any, Iterable, Iterator, Mapping, Sequence


def iter_events(path: Path, max_lines: int | None = None) -> Iterator[dict[str, Any]]:
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for number, line in enumerate(handle, 1):
            if max_lines is not None and number > max_lines:
                break
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                yield {"_parse_error": True, "_line_number": number}
                continue
            if isinstance(value, dict):
                yield value


def rows(counter: collections.Counter[str], top: int) -> list[dict[str, Any]]:
    return [{"value": value, "count": count} for value, count in counter.most_common(top)]


def mask_public_ip(value: str, salt: str) -> str:
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return value
    if address.is_private or address.is_loopback or address.is_link_local:
        return value
    return "public-" + hashlib.sha256((salt + value).encode()).hexdigest()[:12]


def summarize(events: Iterable[Mapping[str, Any]], *, top: int = 20, anonymize_public: bool = False, salt: str = "gunnaire-local") -> dict[str, Any]:
    total = parse_errors = 0
    counters = {name: collections.Counter() for name in ("event_types", "signatures", "categories", "actions", "severities", "sources", "destinations", "protocols")}
    first = last = None
    for event in events:
        total += 1
        if event.get("_parse_error"):
            parse_errors += 1
            continue
        counters["event_types"][str(event.get("event_type", "unknown"))] += 1
        timestamp = event.get("timestamp")
        if isinstance(timestamp, str):
            first = timestamp if first is None or timestamp < first else first
            last = timestamp if last is None or timestamp > last else last
        if event.get("proto") is not None:
            counters["protocols"][str(event["proto"])] += 1
        for field, counter_name in (("src_ip", "sources"), ("dest_ip", "destinations")):
            value = event.get(field)
            if isinstance(value, str):
                counters[counter_name][mask_public_ip(value, salt) if anonymize_public else value] += 1
        alert = event.get("alert")
        if isinstance(alert, dict):
            for field, counter_name in (("signature", "signatures"), ("category", "categories"), ("action", "actions"), ("severity", "severities")):
                if alert.get(field) is not None:
                    counters[counter_name][str(alert[field])] += 1
    return {
        "schema_version": 1,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "total_lines": total, "parse_errors": parse_errors, "first_timestamp": first, "last_timestamp": last,
        **{("top_" + name if name not in {"event_types", "actions", "severities", "protocols"} else name): rows(counter, top) for name, counter in counters.items()},
        "anonymized_public_ips": anonymize_public,
        "advisory_note": "Counts are deterministic; investigate context before changing rules.",
    }


def markdown(summary: Mapping[str, Any], source: Path) -> str:
    lines = ["# Suricata Daily Summary", "", f"Source: `{source}`", f"Created: {summary['created_at']}", f"Lines: {summary['total_lines']}", f"Parse errors: {summary['parse_errors']}", f"Window: {summary['first_timestamp']} through {summary['last_timestamp']}", ""]
    for heading, key in (("Top signatures", "top_signatures"), ("Top categories", "top_categories"), ("Actions", "actions"), ("Severities", "severities"), ("Top sources", "top_sources"), ("Top destinations", "top_destinations")):
        lines += [f"## {heading}", "", "| Value | Count |", "|---|---:|"]
        data = summary.get(key, [])
        lines += [f"| {str(item['value']).replace('|', '\\|')} | {item['count']} |" for item in data] or ["| No entries | 0 |"]
        lines.append("")
    lines += ["## Review rule", "", "This report does not authorize automatic blocking. Confirm device, flow, signature quality and business impact before changing policy.", ""]
    return "\n".join(lines)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--json-output", type=Path, required=True)
    parser.add_argument("--markdown-output", type=Path)
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--max-lines", type=int)
    parser.add_argument("--anonymize-public-ips", action="store_true")
    parser.add_argument("--anonymization-salt", default="gunnaire-local")
    args = parser.parse_args(argv)
    if not 1 <= args.top <= 1000:
        print("error: --top must be 1 through 1000", file=sys.stderr)
        return 2
    try:
        summary = summarize(iter_events(args.input, args.max_lines), top=args.top, anonymize_public=args.anonymize_public_ips, salt=args.anonymization_salt)
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        if args.markdown_output:
            args.markdown_output.parent.mkdir(parents=True, exist_ok=True)
            args.markdown_output.write_text(markdown(summary, args.input), encoding="utf-8")
        print(args.json_output)
        return 0 if summary["parse_errors"] == 0 else 1
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
