"""Actual native discriminator vocabulary, independent of lossless owner fields."""
from __future__ import annotations

import json
import re
from pathlib import Path

try:
    from Backend import staff_workspace_contract as contract, staff_workspace_selection as selection
except ModuleNotFoundError:
    import staff_workspace_contract as contract
    import staff_workspace_selection as selection

MANIFEST = json.loads(Path(__file__).with_name("staff_workspace_discriminators_v1.json").read_text())
VERSION = "staff-workspace-discriminators-v1"


def rules():
    contract.exact(MANIFEST, "schema ownerSchemaDigest rules")
    result = MANIFEST["rules"]
    if MANIFEST["schema"] != VERSION or MANIFEST["ownerSchemaDigest"] != contract.SCHEMA_DIGEST or set(result) != set(contract.SPECS):
        raise selection.failure("schema_changed")
    extra = {"job": {"type", "status"}, "estimate": {"proposalOption"}, "attachment": {"googleDriveSyncStatus"}}
    for kind, fields in result.items():
        if set(fields) != {name for name in contract.SPECS[kind] if "Raw" in name} | extra.get(kind, set()):
            raise selection.failure("schema_changed")
        for name, rule in fields.items():
            contract.exact(rule, "kind values")
            values = rule["values"]
            if rule["kind"] not in ("text", "integer", "lines", "receiptLines") or type(values) is not list or not values or any(type(v) is not str for v in values) or values != sorted(set(values)):
                raise selection.failure("schema_changed")
            expected = "integer" if rule["kind"] == "integer" else "text"
            if contract.SPECS[kind][name]["type"] != expected:
                raise selection.failure("schema_changed")
    return result


def accepts(rule, value):
    if value is None:
        return True  # Required-null checks belong to the original typed schema.
    if rule["kind"] == "integer":
        return type(value) is int and str(value) in rule["values"]
    if type(value) is not str:
        return False
    if rule["kind"] == "text":
        return value in rule["values"]
    if value == "":
        return True
    lines = value.split("\n")
    if len(lines) > 20_000 or len(lines) != len(set(lines)):
        return False
    if rule["kind"] == "lines":
        return set(lines) <= set(rule["values"])
    for line in lines:
        entity, separator, reference = line.partition(":")
        if not separator or entity not in rule["values"] or reference in (".", "..") or re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", reference) is None:
            return False
    return True


def validate(graph):
    for kind, fields in rules().items():
        for identity in graph.live[kind]:
            for field, rule in fields.items():
                if not accepts(rule, graph.value(kind, identity, field)):
                    raise selection.failure("discriminator_pending")
