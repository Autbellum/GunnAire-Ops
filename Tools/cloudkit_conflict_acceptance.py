#!/usr/bin/env python3
"""Capture and validate privacy-minimal CloudKit conflict probe evidence.

The Debug probe overwrites its report after every launch. This tool validates
each report against the exact expected phase before retaining a sanitized,
append-only evidence file. It never launches an app, changes network state,
contacts CloudKit, or stores device/account/customer/payment identifiers.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

try:
    from Tools import release_preflight
except ModuleNotFoundError:  # Direct execution from the Tools directory.
    import release_preflight


EVIDENCE_SCHEMA_VERSION = 1
PROBE_SCHEMA_VERSION = 2
MAXIMUM_ATTEMPT = 5
REPORT_KEYS = {
    "schemaVersion",
    "generatedAtUTC",
    "applicationBuild",
    "mode",
    "attempt",
    "state",
    "matchCount",
    "actionPerformed",
    "expectationMet",
    "errorCode",
}
EVIDENCE_KEYS = {
    "schemaVersion",
    "phase",
    "sourceDeviceClass",
    "capturedAtUTC",
    "sourceReportSHA256",
    "probe",
}
SANITIZED_PROBE_KEYS = {
    "schemaVersion",
    "generatedAtUTC",
    "applicationBuild",
    "mode",
    "attempt",
    "state",
    "matchCount",
    "actionPerformed",
    "expectationMet",
    "errorPresent",
}


@dataclass(frozen=True)
class Phase:
    identifier: str
    device_class: str
    mode: str
    state: str
    match_count: int

    @property
    def file_name(self) -> str:
        index = PHASES.index(self) + 1
        return f"{index:02d}-{self.identifier}.json"


PHASES = (
    Phase("mac-seed", "Mac", "seedConflict", "original", 1),
    Phase("ipad-observe-seed", "iPad", "observeConflictSeed", "original", 1),
    Phase("mac-offline-write-a", "Mac", "writeConflictA", "conflictA", 2),
    Phase("ipad-offline-write-b", "iPad", "writeConflictB", "conflictB", 2),
    Phase(
        "mac-observe-converged",
        "Mac",
        "observeConflictConverged",
        "conflictConverged",
        3,
    ),
    Phase(
        "ipad-observe-converged",
        "iPad",
        "observeConflictConverged",
        "conflictConverged",
        3,
    ),
    Phase("mac-resolve", "Mac", "resolveConflict", "conflictResolved", 4),
    Phase(
        "ipad-observe-resolved",
        "iPad",
        "observeConflictResolved",
        "conflictResolved",
        4,
    ),
    Phase("mac-cleanup", "Mac", "cleanupConflict", "absent", 0),
    Phase(
        "ipad-observe-deleted",
        "iPad",
        "observeConflictDeleted",
        "absent",
        0,
    ),
)
PHASE_BY_ID = {phase.identifier: phase for phase in PHASES}


def parse_args() -> argparse.Namespace:
    project_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=project_root)
    parser.add_argument("--expected-build", help="Defaults to the current Xcode build number.")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--capture", choices=tuple(PHASE_BY_ID))
    action.add_argument("--validate-directory", type=Path)
    parser.add_argument("--report", type=Path, help="Raw probe report to validate and sanitize.")
    parser.add_argument(
        "--evidence-directory",
        type=Path,
        help="New or existing directory for the fixed phase evidence filenames.",
    )
    return parser.parse_args()


def parse_utc_timestamp(value: Any, field_name: str, errors: list[str]) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{field_name} is required")
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        errors.append(f"{field_name} must be an ISO-8601 timestamp")
        return None
    if parsed.tzinfo is None:
        errors.append(f"{field_name} must include a UTC offset")
        return None
    return parsed.astimezone(timezone.utc)


def validate_probe_report(
    report: Any,
    *,
    phase: Phase,
    expected_build: str,
    now: datetime | None = None,
) -> list[str]:
    if not isinstance(report, dict):
        return ["probe report must be a JSON object"]
    errors: list[str] = []
    keys = set(report)
    if keys != REPORT_KEYS:
        missing = sorted(REPORT_KEYS - keys)
        unexpected = sorted(keys - REPORT_KEYS)
        if missing:
            errors.append(f"probe report is missing keys: {', '.join(missing)}")
        if unexpected:
            errors.append(f"probe report contains unexpected keys: {', '.join(unexpected)}")
    expected_values = {
        "schemaVersion": PROBE_SCHEMA_VERSION,
        "applicationBuild": expected_build,
        "mode": phase.mode,
        "state": phase.state,
        "matchCount": phase.match_count,
        "expectationMet": True,
        "errorCode": None,
    }
    for key, expected in expected_values.items():
        if report.get(key) != expected:
            errors.append(f"{key} must equal {expected!r}, found {report.get(key)!r}")
    attempt = report.get("attempt")
    if isinstance(attempt, bool) or not isinstance(attempt, int) or not 1 <= attempt <= MAXIMUM_ATTEMPT:
        errors.append(f"attempt must be an integer from 1 through {MAXIMUM_ATTEMPT}")
    if not isinstance(report.get("actionPerformed"), bool):
        errors.append("actionPerformed must be a Boolean")
    generated = parse_utc_timestamp(report.get("generatedAtUTC"), "generatedAtUTC", errors)
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    if generated and generated > current + timedelta(minutes=5):
        errors.append("generatedAtUTC cannot be more than five minutes in the future")
    return errors


def sanitized_evidence(
    report: dict[str, Any],
    *,
    phase: Phase,
    source_bytes: bytes,
    captured_at: datetime | None = None,
) -> dict[str, Any]:
    captured = (captured_at or datetime.now(timezone.utc)).astimezone(timezone.utc)
    return {
        "schemaVersion": EVIDENCE_SCHEMA_VERSION,
        "phase": phase.identifier,
        "sourceDeviceClass": phase.device_class,
        "capturedAtUTC": captured.isoformat().replace("+00:00", "Z"),
        "sourceReportSHA256": hashlib.sha256(source_bytes).hexdigest(),
        "probe": {
            "schemaVersion": report["schemaVersion"],
            "generatedAtUTC": report["generatedAtUTC"],
            "applicationBuild": report["applicationBuild"],
            "mode": report["mode"],
            "attempt": report["attempt"],
            "state": report["state"],
            "matchCount": report["matchCount"],
            "actionPerformed": report["actionPerformed"],
            "expectationMet": report["expectationMet"],
            "errorPresent": report["errorCode"] is not None,
        },
    }


def write_new_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2, sort_keys=False)
        stream.write("\n")


def validate_captured_evidence(
    evidence: Any,
    *,
    phase: Phase,
    expected_build: str,
) -> tuple[list[str], datetime | None]:
    if not isinstance(evidence, dict):
        return ["evidence must be a JSON object"], None
    errors: list[str] = []
    keys = set(evidence)
    if keys != EVIDENCE_KEYS:
        missing = sorted(EVIDENCE_KEYS - keys)
        unexpected = sorted(keys - EVIDENCE_KEYS)
        if missing:
            errors.append(f"evidence is missing keys: {', '.join(missing)}")
        if unexpected:
            errors.append(f"evidence contains unexpected keys: {', '.join(unexpected)}")
    if evidence.get("schemaVersion") != EVIDENCE_SCHEMA_VERSION:
        errors.append(f"schemaVersion must equal {EVIDENCE_SCHEMA_VERSION}")
    if evidence.get("phase") != phase.identifier:
        errors.append(f"phase must equal {phase.identifier!r}")
    if evidence.get("sourceDeviceClass") != phase.device_class:
        errors.append(f"sourceDeviceClass must equal {phase.device_class!r}")
    digest = evidence.get("sourceReportSHA256")
    if not isinstance(digest, str) or re_full_sha256(digest) is False:
        errors.append("sourceReportSHA256 must be a lowercase SHA-256 digest")
    captured = parse_utc_timestamp(evidence.get("capturedAtUTC"), "capturedAtUTC", errors)
    probe = evidence.get("probe")
    if not isinstance(probe, dict):
        errors.append("probe must be a JSON object")
        return errors, captured
    probe_keys = set(probe)
    if probe_keys != SANITIZED_PROBE_KEYS:
        missing = sorted(SANITIZED_PROBE_KEYS - probe_keys)
        unexpected = sorted(probe_keys - SANITIZED_PROBE_KEYS)
        if missing:
            errors.append(f"probe is missing keys: {', '.join(missing)}")
        if unexpected:
            errors.append(f"probe contains unexpected keys: {', '.join(unexpected)}")
    expected_probe = {
        "schemaVersion": PROBE_SCHEMA_VERSION,
        "applicationBuild": expected_build,
        "mode": phase.mode,
        "state": phase.state,
        "matchCount": phase.match_count,
        "expectationMet": True,
        "errorPresent": False,
    }
    for key, expected in expected_probe.items():
        if probe.get(key) != expected:
            errors.append(f"probe.{key} must equal {expected!r}, found {probe.get(key)!r}")
    if not isinstance(probe.get("actionPerformed"), bool):
        errors.append("probe.actionPerformed must be a Boolean")
    attempt = probe.get("attempt")
    if isinstance(attempt, bool) or not isinstance(attempt, int) or not 1 <= attempt <= MAXIMUM_ATTEMPT:
        errors.append(f"probe.attempt must be an integer from 1 through {MAXIMUM_ATTEMPT}")
    parse_utc_timestamp(probe.get("generatedAtUTC"), "probe.generatedAtUTC", errors)
    return errors, captured


def re_full_sha256(value: str) -> bool:
    return len(value) == 64 and all(character in "0123456789abcdef" for character in value)


def validate_directory(directory: Path, *, expected_build: str) -> list[str]:
    errors: list[str] = []
    captured_times: list[tuple[str, datetime]] = []
    for phase in PHASES:
        path = directory / phase.file_name
        try:
            evidence = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            errors.append(f"missing phase evidence: {phase.file_name}")
            continue
        except (OSError, json.JSONDecodeError) as error:
            errors.append(f"could not read {phase.file_name}: {error}")
            continue
        phase_errors, captured = validate_captured_evidence(
            evidence,
            phase=phase,
            expected_build=expected_build,
        )
        errors.extend(f"{phase.file_name}: {error}" for error in phase_errors)
        if captured:
            captured_times.append((phase.file_name, captured))
    for previous, current in zip(captured_times, captured_times[1:]):
        if current[1] < previous[1]:
            errors.append(
                f"capture order is invalid: {current[0]} precedes {previous[0]}"
            )
    return errors


def current_build(project_root: Path) -> str:
    project_file = project_root / "GunnAire Ops.xcodeproj" / "project.pbxproj"
    _, build_version = release_preflight.source_versions(project_file)
    return build_version


def load_json_bytes(path: Path) -> tuple[bytes, Any]:
    source_bytes = path.read_bytes()
    return source_bytes, json.loads(source_bytes)


def main() -> int:
    args = parse_args()
    expected_build = args.expected_build or current_build(args.project_root)
    if args.capture:
        if args.report is None or args.evidence_directory is None:
            print("ERROR   --capture requires --report and --evidence-directory", file=sys.stderr)
            return 2
        phase = PHASE_BY_ID[args.capture]
        try:
            source_bytes, report = load_json_bytes(args.report)
        except (OSError, json.JSONDecodeError) as error:
            print(f"ERROR   probe report could not be read: {error}", file=sys.stderr)
            return 2
        errors = validate_probe_report(report, phase=phase, expected_build=expected_build)
        if errors:
            for error in errors:
                print(f"FAILED  {error}")
            return 1
        destination = args.evidence_directory / phase.file_name
        try:
            write_new_json(
                destination,
                sanitized_evidence(report, phase=phase, source_bytes=source_bytes),
            )
        except FileExistsError:
            print(f"ERROR   refusing to overwrite existing evidence: {destination}", file=sys.stderr)
            return 2
        except OSError as error:
            print(f"ERROR   evidence could not be written: {error}", file=sys.stderr)
            return 2
        print(f"CAPTURED  {phase.identifier}: {destination}")
        return 0

    errors = validate_directory(args.validate_directory, expected_build=expected_build)
    if errors:
        for error in errors:
            print(f"INCOMPLETE  {error}")
        print(f"CLOUDKIT CONFLICT EVIDENCE: INCOMPLETE ({len(errors)} issue(s))")
        return 1
    print("CLOUDKIT CONFLICT EVIDENCE: PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
