"""Versioned owner archive contract exported from the native typed model catalog.

This preserves original owner values, not validated accounting instructions or
a role-filtered staff snapshot. Nested JSON is opaque here and must be validated
by the consuming domain before import, staff projection, or provider mutation.
"""
from __future__ import annotations

import hashlib
import json
import math
import uuid
from pathlib import Path

try:
    from Backend import cloudkit_staff_shares as sharing
except ModuleNotFoundError:
    import cloudkit_staff_shares as sharing

SCHEMA_VERSION = "owner-workspace-v1"
MAX_RECORD_BYTES = 2 * 1024 * 1024
MAX_BATCH_BYTES = 8 * 1024 * 1024
MAX_PAGE_BYTES = 8 * 1024 * 1024
MAX_SCAN_BYTES = 64 * 1024 * 1024
MAX_RECORDS = 100_000  # Includes retained tombstones; never truncate silently.


def canonical(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":"))


def wire(value):
    # Match the HTTP handler's ASCII-escaped JSON size, including Unicode.
    return json.dumps(value, ensure_ascii=True, allow_nan=False, sort_keys=True, separators=(",", ":"))


SPECS = json.loads(Path(__file__).with_name("staff_workspace_schema_v1.json").read_text(encoding="utf-8"))
SCHEMA_DIGEST = hashlib.sha256(canonical(SPECS).encode()).hexdigest()


def invalid():
    return sharing.fail("invalid_request", "Use the complete supported owner record without dropping or changing its typed fields.", 400)


def exact(value, names):
    if type(value) is not dict or set(value) != set(names.split()):
        raise invalid()


def integer(value, minimum=0):
    if type(value) is not int or not minimum <= value < 2_147_483_647:
        raise invalid()
    return value


def validate(kind, fields):
    if type(kind) is not str or kind not in SPECS or type(fields) is not dict or set(fields) != set(SPECS[kind]):
        raise invalid()
    for name, spec in SPECS[kind].items():
        atom = fields[name]
        if type(atom) is not dict or len(atom) != 1:
            raise invalid()
        if atom == {"null": {}}:
            if not spec["nullable"]:
                raise invalid()
            continue
        tag = spec["type"]
        exact(atom, tag)
        exact(atom[tag], "_0")
        value = atom[tag]["_0"]
        if tag == "text":
            if (type(value) is not str or "\0" in value or any(0xD800 <= ord(c) <= 0xDFFF for c in value)
                    or len(value.encode("utf-8")) > 1_048_576):
                raise invalid()
            if "enumeration" in spec and value not in spec["enumeration"]:
                raise invalid()
        elif tag == "integer":
            if type(value) is not int or not -2_147_483_647 <= value <= 2_147_483_647:
                raise invalid()
        elif tag in ("number", "date"):
            bound = 1e12 if tag == "number" else 1e11
            # Check magnitude before isfinite: a hostile enormous JSON integer
            # must be rejected, not overflow during conversion to float.
            if type(value) not in (int, float) or not -bound <= value <= bound or not math.isfinite(value):
                raise invalid()
        elif tag == "flag":
            if type(value) is not bool:
                raise invalid()
        elif tag == "identifier":
            if type(value) is not str:
                raise invalid()
            try:
                if str(uuid.UUID(value)).upper() != value:
                    raise ValueError()
            except ValueError:
                raise invalid() from None
        else:
            raise RuntimeError("Unsupported owner schema type")
    if len(canonical(fields).encode()) > MAX_RECORD_BYTES:
        raise invalid()


def change(value):
    exact(value, "kind id expectedRevision action fields")
    sharing.identifier(value["id"])
    integer(value["expectedRevision"])
    if type(value["kind"]) is not str or value["kind"] not in SPECS or value["action"] not in ("upsert", "delete", "restore"):
        raise invalid()
    if value["action"] == "delete":
        if value["fields"] != {}:
            raise invalid()
    else:
        validate(value["kind"], value["fields"])
    if value["action"] != "upsert" and value["expectedRevision"] == 0:
        raise invalid()
    if len(canonical(value).encode()) > MAX_RECORD_BYTES:
        raise invalid()
