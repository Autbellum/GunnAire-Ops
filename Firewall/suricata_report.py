#!/usr/bin/env python3
"""Produce deterministic JSON/Markdown summaries from Suricata EVE JSON logs."""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import hmac
import ipaddress
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable, Iterator, Mapping, Sequence


def iter_events(path: Path, max_lines: int | None = None) -> Iterator[dict[str, Any]]:
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line_number, line in enumerate(handle, start=1):
            if max_lines is not None and line_number > max_lines:
                break
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                yield {"_parse_error": True, "_line_number": line_number}
                continue
            if isinstance(value, dict):
                yield value
            else:
                yield {"_parse_error": True, "_line_number": line_number}


def _public_token(value: str, salt: str) -> str:
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return value
    if address.is_private or address.is_loopback or address.is_link_local:
        return value
    return "public-" + hmac.new(salt.encode(), str(address).encode(), hashlib.sha256).hexdigest()[:24]


def _rows(counter: collections.Counter[str], top: int) -> list[dict[str, Any]]:
    return [{"value": value, "count": count} for value, count in counter.most_common(top)]


def summarize(events: Iterable[Mapping[str, Any]], *, top: int = 20, anonymize_public: bool = False, salt: str | None = None) -> dict[str, Any]:
    if anonymize_public and (not isinstance(salt, str) or len(salt) < 32):
        raise ValueError("Address pseudonymization requires a private installation key")
    total = 0
    parse_errors = 0
    first: str | None = None
    last: str | None = None
    counters = {name: collections.Counter() for name in ("event_types", "signatures", "categories", "actions", "severities", "sources", "destinations", "protocols")}
    for event in events:
        total += 1
        if event.get("_parse_error"):
            parse_errors += 1
            continue
        timestamp = event.get("timestamp")
        if isinstance(timestamp, str):
            try:
                instant = dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
                if instant.tzinfo is None:
                    raise ValueError("Timestamp requires timezone")
                normalized = instant.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")
                first = normalized if first is None or normalized < first else first
                last = normalized if last is None or normalized > last else last
            except ValueError:
                parse_errors += 1
        counters["event_types"][str(event.get("event_type", "unknown"))] += 1
        if event.get("proto") is not None:
            counters["protocols"][str(event["proto"])] += 1
        for field, counter_name in (("src_ip", "sources"), ("dest_ip", "destinations")):
            value = event.get(field)
            if isinstance(value, str):
                counters[counter_name][_public_token(value, salt) if anonymize_public else value] += 1
        alert = event.get("alert")
        if isinstance(alert, dict):
            for field, counter_name in (("signature", "signatures"), ("category", "categories"), ("action", "actions"), ("severity", "severities")):
                if alert.get(field) is not None:
                    counters[counter_name][str(alert[field])] += 1
    return {
        "schema_version": 1,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "total_lines": total,
        "parse_errors": parse_errors,
        "first_timestamp": first,
        "last_timestamp": last,
        "event_types": _rows(counters["event_types"], top),
        "top_signatures": _rows(counters["signatures"], top),
        "top_categories": _rows(counters["categories"], top),
        "actions": _rows(counters["actions"], top),
        "severities": _rows(counters["severities"], top),
        "top_sources": _rows(counters["sources"], top),
        "top_destinations": _rows(counters["destinations"], top),
        "protocols": _rows(counters["protocols"], top),
        "anonymized_public_ips": anonymize_public,
        "advisory_note": "Counts are deterministic; investigate context before changing any rule."
    }


def markdown_cell(value: Any) -> str:
    value = " ".join(str(value).splitlines())
    return re.sub(r"([\\`*_{}\[\]()#+.!|<>])", r"\\\1", value)


def render_markdown(summary: Mapping[str, Any], source: Path) -> str:
    lines = [
        "# Suricata Daily Summary", "", f"Source: {markdown_cell(source)}", f"Created: {summary.get('created_at')}",
        f"Lines: {summary.get('total_lines')}  ", f"Parse errors: {summary.get('parse_errors')}  ",
        f"Window: {summary.get('first_timestamp')} through {summary.get('last_timestamp')}", ""
    ]
    for heading, key in (("Top signatures", "top_signatures"), ("Top categories", "top_categories"), ("Actions", "actions"), ("Severities", "severities"), ("Top sources", "top_sources"), ("Top destinations", "top_destinations")):
        lines += [f"## {heading}", ""]
        rows = summary.get(key, [])
        if not rows:
            lines.append("No entries.")
        else:
            lines += ["| Value | Count |", "|---|---:|"]
            for row in rows:
                value = markdown_cell(row.get("value", ""))
                lines.append(f"| {value} | {row.get('count', 0)} |")
        lines.append("")
    lines += ["## Review rule", "", "This report does not authorize automatic blocking. Confirm device, flow, signature quality, and business impact before changing IDS/IPS policy.", ""]
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--json-output", type=Path, required=True)
    parser.add_argument("--markdown-output", type=Path)
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--max-lines", type=int)
    parser.add_argument("--anonymize-public-ips", action="store_true")
    parser.add_argument("--anonymization-key-file", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not 1 <= args.top <= 1000:
        print("error: --top must be 1 through 1000", file=sys.stderr)
        return 2
    try:
        if args.max_lines is not None and args.max_lines <= 0:
            raise ValueError("--max-lines must be positive")
        args.input = args.input.expanduser().resolve(strict=True)
        outputs = [p.expanduser().resolve() for p in (args.json_output, args.markdown_output) if p is not None]
        if len(set(outputs)) != len(outputs) or args.input in outputs or any(
                p.exists() and p.samefile(args.input) for p in outputs):
            raise ValueError("Source and output paths must be distinct")
        args.json_output = outputs[0]
        args.markdown_output = outputs[1] if len(outputs) > 1 else None
        key = None
        if args.anonymize_public_ips:
            if args.anonymization_key_file is None:
                raise ValueError("A private key file is required")
            key_path = args.anonymization_key_file.expanduser().resolve(strict=True)
            if key_path in outputs or key_path == args.input or key_path.stat().st_mode & 0o077:
                raise ValueError("Key must be private and separate from input/output")
            key = key_path.read_text().strip()
        summary = summarize(iter_events(args.input, args.max_lines), top=args.top, anonymize_public=args.anonymize_public_ips, salt=key)
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        if args.markdown_output:
            args.markdown_output.parent.mkdir(parents=True, exist_ok=True)
            args.markdown_output.write_text(render_markdown(summary, args.input), encoding="utf-8")
        print(args.json_output)
        return 0 if summary["parse_errors"] == 0 else 1
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
