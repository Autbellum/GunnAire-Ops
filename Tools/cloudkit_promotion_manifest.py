#!/usr/bin/env python3
"""Build a privacy-minimal, fail-closed CloudKit Production promotion manifest.

The utility compares schema exports only. It never connects to CloudKit,
deploys a schema, or reads application/customer records.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

try:
    from Tools import release_preflight
except ModuleNotFoundError:  # Direct execution from the Tools directory.
    import release_preflight


def _field_path(record_name: str, field_name: str) -> str:
    return f"{record_name}.{field_name}"


def _approved_record_type_set(record_types: set[str]) -> bool:
    baseline = release_preflight.EXPECTED_CLOUDKIT_BASELINE_RECORD_TYPES
    groups = (
        release_preflight.EXPECTED_CLOUDKIT_V17_RECORD_TYPES,
        release_preflight.EXPECTED_CLOUDKIT_V18_RECORD_TYPES,
        release_preflight.EXPECTED_CLOUDKIT_V19_RECORD_TYPES,
        release_preflight.EXPECTED_CLOUDKIT_V20_RECORD_TYPES,
        release_preflight.EXPECTED_CLOUDKIT_V21_RECORD_TYPES,
        release_preflight.EXPECTED_CLOUDKIT_V22_RECORD_TYPES,
    )
    if not baseline.issubset(record_types):
        return False
    allowed = set(baseline)
    for group in groups:
        present = record_types & group
        if present not in (set(), group):
            return False
        allowed.update(group)
    return record_types.issubset(allowed)


def build_manifest(
    development: dict[str, dict[str, tuple[str, ...]]],
    production: dict[str, dict[str, tuple[str, ...]]],
    development_metadata: dict[str, dict[str, tuple[str, ...]]],
    production_metadata: dict[str, dict[str, tuple[str, ...]]],
    *,
    development_sha256: str,
    production_sha256: str,
) -> dict[str, Any]:
    development_types = set(development)
    production_types = set(production)
    added_record_types = sorted(development_types - production_types)

    actual_additions: dict[str, dict[str, tuple[str, ...]]] = {}
    for record_name in sorted(development):
        additions = {
            field_name: definition
            for field_name, definition in sorted(development[record_name].items())
            if field_name not in production.get(record_name, {})
        }
        if additions:
            actual_additions[record_name] = additions

    changed_or_removed_fields = []
    for record_name in sorted(production):
        for field_name, production_definition in sorted(production[record_name].items()):
            development_definition = development.get(record_name, {}).get(field_name)
            if development_definition != production_definition:
                changed_or_removed_fields.append(
                    {
                        "path": _field_path(record_name, field_name),
                        "productionDefinition": list(production_definition),
                        "developmentDefinition": (
                            list(development_definition)
                            if development_definition is not None
                            else None
                        ),
                    }
                )

    changed_existing_metadata = [
        record_name
        for record_name in sorted(production_types)
        if development_metadata.get(record_name) != production_metadata.get(record_name)
    ]
    invalid_added_record_metadata = [
        record_name
        for record_name in added_record_types
        if development_metadata.get(record_name, {}).get("system_fields")
        != release_preflight.EXPECTED_CLOUDKIT_SYSTEM_FIELDS
        or development_metadata.get(record_name, {}).get("grants")
        != release_preflight.EXPECTED_CLOUDKIT_RECORD_GRANTS
    ]

    expected_v23 = release_preflight.EXPECTED_CLOUDKIT_V23_ADDITIONS
    expected_remaining = {
        record_name: {
            field_name: definition
            for field_name, definition in expected_fields.items()
            if production.get(record_name, {}).get(field_name) != definition
        }
        for record_name, expected_fields in expected_v23.items()
    }
    expected_remaining = {
        record_name: fields
        for record_name, fields in expected_remaining.items()
        if fields
    }
    missing_or_changed_development_v23_fields = sorted(
        _field_path(record_name, field_name)
        for record_name, expected_fields in expected_v23.items()
        for field_name, expected_definition in expected_fields.items()
        if development.get(record_name, {}).get(field_name) != expected_definition
    )

    checks = {
        "productionRecordTypesAreSubsetOfDevelopment": production_types.issubset(
            development_types
        ),
        "developmentRecordTypesAreApproved": _approved_record_type_set(
            development_types
        ),
        "productionRecordTypesAreApproved": _approved_record_type_set(production_types),
        "existingFieldsAreUnchanged": not changed_or_removed_fields,
        "existingMetadataIsUnchanged": not changed_existing_metadata,
        "addedRecordMetadataIsApproved": not invalid_added_record_metadata,
        "developmentContainsExactV23Fields": not missing_or_changed_development_v23_fields,
        "deltaExactlyMatchesRemainingV23Additions": actual_additions
        == expected_remaining,
    }
    safe_to_promote = all(checks.values())
    added_field_count = sum(len(fields) for fields in actual_additions.values())

    return {
        "schemaVersion": 1,
        "operation": "CloudKit schema export comparison",
        "environmentDirection": "Development to Production",
        "privacy": {
            "schemaOnly": True,
            "applicationRecordsRead": False,
            "deploymentPerformed": False,
        },
        "inputs": {
            "developmentSHA256": development_sha256,
            "productionSHA256": production_sha256,
        },
        "summary": {
            "developmentRecordTypeCount": len(development_types),
            "productionRecordTypeCount": len(production_types),
            "addedRecordTypeCount": len(added_record_types),
            "addedFieldCount": added_field_count,
            "fieldsOnAddedRecordTypes": sum(
                len(actual_additions.get(record_name, {}))
                for record_name in added_record_types
            ),
            "fieldsOnExistingRecordTypes": added_field_count
            - sum(
                len(actual_additions.get(record_name, {}))
                for record_name in added_record_types
            ),
            "riskClassification": "additive-only" if safe_to_promote else "blocked",
            "safeToPromote": safe_to_promote,
        },
        "checks": checks,
        "changes": {
            "addedRecordTypes": added_record_types,
            "addedFields": {
                record_name: [
                    {"name": field_name, "definition": list(definition)}
                    for field_name, definition in fields.items()
                ]
                for record_name, fields in actual_additions.items()
            },
            "changedOrRemovedFields": changed_or_removed_fields,
            "changedExistingMetadata": changed_existing_metadata,
            "invalidAddedRecordMetadata": invalid_added_record_metadata,
            "missingOrChangedDevelopmentV23Fields": (
                missing_or_changed_development_v23_fields
            ),
        },
    }


def build_manifest_from_paths(development: Path, production: Path) -> dict[str, Any]:
    return build_manifest(
        release_preflight.parse_cloudkit_schema(development),
        release_preflight.parse_cloudkit_schema(production),
        release_preflight.parse_cloudkit_record_metadata(development),
        release_preflight.parse_cloudkit_record_metadata(production),
        development_sha256=release_preflight.sha256(development),
        production_sha256=release_preflight.sha256(production),
    )


def write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--development", required=True, type=Path)
    parser.add_argument("--production", required=True, type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        help="Optional JSON output path. Without it, the manifest is printed.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        manifest = build_manifest_from_paths(
            args.development.expanduser().resolve(),
            args.production.expanduser().resolve(),
        )
    except (OSError, ValueError) as error:
        print(f"CloudKit promotion manifest failed: {error}", file=sys.stderr)
        return 2

    if args.output is not None:
        output = args.output.expanduser().resolve()
        write_manifest(output, manifest)
        print(output)
    else:
        print(json.dumps(manifest, indent=2))
    return 0 if manifest["summary"]["safeToPromote"] else 1


if __name__ == "__main__":
    sys.exit(main())
