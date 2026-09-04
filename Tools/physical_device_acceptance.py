#!/usr/bin/env python3
"""Read-only readiness and evidence gate for GunnAire signed-device acceptance.

The default inspection inventories local signing identities, the exact retained
release artifacts, and paired physical Apple devices. It never installs an app,
changes a device, promotes CloudKit, or calls a payment/accounting mutation.

An acceptance record can be generated as an incomplete template and validated
after a human performs the required workflows. The validator refuses to treat
missing evidence, stale builds, production-provider work without an approval
reference, or an incomplete scenario as release acceptance.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

try:
    from Tools import release_preflight
except ModuleNotFoundError:  # Direct execution from the Tools directory.
    import release_preflight


SCHEMA_VERSION = 1
EXPECTED_BUNDLE_ID = "com.gunnaire.businesssuite"
EXPECTED_TEAM_ID = "7C4B3RR7RD"


@dataclass(frozen=True)
class AcceptanceScenario:
    identifier: str
    title: str
    expected_evidence: str


REQUIRED_SCENARIOS = (
    AcceptanceScenario(
        "apple-sign-in-role-session",
        "Fresh Apple sign-in, session renewal, and role resolution",
        "Allowed and denied roles without exposing the account email.",
    ),
    AcceptanceScenario(
        "ipad-navigation-accessibility",
        "iPad navigation, keyboard commands, Dynamic Type, VoiceOver, and Reduce Motion",
        "Primary work remains uncluttered, reachable, role scoped, and nonanimated when requested.",
    ),
    AcceptanceScenario(
        "mac-navigation-keyboard",
        "Mac Catalyst navigation, keyboard commands, windows, and handoffs",
        "Evidence from the universal current-build Mac app.",
    ),
    AcceptanceScenario(
        "offline-service-repair-replacement",
        "Offline Service, Repair, and Replacement field files and closeout",
        "Findings, forms, files, parts, labor, approval, closeout, and reconnect.",
    ),
    AcceptanceScenario(
        "cloudkit-two-device-online-sync",
        "Two-device CloudKit create/update/delete convergence",
        "Before/after evidence from signed company devices.",
    ),
    AcceptanceScenario(
        "cloudkit-offline-reconnect",
        "CloudKit offline queue, relaunch, reconnect, and durable recovery",
        "Unsynced work remains visible and converges after reconnect.",
    ),
    AcceptanceScenario(
        "cloudkit-conflict-account-loss",
        "CloudKit conflict, account loss, reassignment, and fail-closed recovery",
        "Visible recovery and blocked unsafe actions.",
    ),
    AcceptanceScenario(
        "ipad-to-iphone-payment-handoff",
        "iPad-to-iPhone field-payment Handoff",
        "Authorized invoice, balance, QBO reference, and supported payment guide.",
    ),
    AcceptanceScenario(
        "mac-to-iphone-payment-handoff",
        "Mac-to-iPhone field-payment Handoff",
        "Authorized current-build Mac origin and iPhone receipt.",
    ),
    AcceptanceScenario(
        "handoff-expiry-revocation-privacy",
        "Handoff expiry, revocation, delayed sync, and payload privacy",
        "Stale routes fail closed and carry only the invoice UUID.",
    ),
    AcceptanceScenario(
        "qbo-sandbox-item-create-update",
        "Technician-created item review and duplicate-safe QBO publication",
        "Sandbox item ID, review approval, retry state, and reconciliation.",
    ),
    AcceptanceScenario(
        "qbo-sandbox-invoice-line-reconcile",
        "Invoice line create/update and exact QBO reconciliation",
        "Sandbox ID, SyncToken, quantities, prices, tax, discount, and snapshot.",
    ),
    AcceptanceScenario(
        "qbo-sandbox-duplicate-recovery",
        "QBO timeout, lost-response, duplicate prevention, and recovery",
        "Stable request marker and exactly one provider record.",
    ),
    AcceptanceScenario(
        "payment-handoff-recovery",
        "Supported payment success, decline, interruption, and reconciliation",
        "Provider evidence without card data or redirect-inferred success.",
    ),
    AcceptanceScenario(
        "google-gmail-calendar-drive",
        "Google sign-in, Gmail, Calendar, and duplicate-safe Drive archive",
        "Approved business-account evidence including revocation and retry.",
    ),
    AcceptanceScenario(
        "push-assignment-route-revocation",
        "APNs assignment delivery, tap routing, logout, and token revocation",
        "Sandbox/TestFlight evidence with a privacy-minimal preview.",
    ),
    AcceptanceScenario(
        "dispatch-override-role-boundaries",
        "Dispatch override, conflicts, audit history, and every access level",
        "Allowed/denied evidence for Admin, Dispatch, Accounting, Field, Standard.",
    ),
    AcceptanceScenario(
        "camera-equipment-label",
        "Equipment barcode/QR capture and printed asset-label round trip",
        "Physical manufacturer and GunnAire label scan evidence.",
    ),
    AcceptanceScenario(
        "logout-device-loss-revocation",
        "Logout, credential revocation, device loss, and local-data protection",
        "Sessions, notifications, handoffs, and unsafe work fail closed.",
    ),
)


@dataclass(frozen=True)
class DeviceSummary:
    device_ref: str
    device_type: str
    marketing_name: str
    os_version: str
    pairing_state: str
    tunnel_state: str
    developer_mode: str
    ddi_services_available: bool
    installed_marketing_version: str | None = None
    installed_build_version: str | None = None
    app_inspection_succeeded: bool = False

    @property
    def is_available(self) -> bool:
        return (
            self.pairing_state.lower() == "paired"
            and self.tunnel_state.lower() in {"available", "connected"}
            and self.developer_mode.lower() == "enabled"
            and self.ddi_services_available
        )

    def has_current_build(self, marketing_version: str, build_version: str) -> bool:
        return (
            self.is_available
            and self.app_inspection_succeeded
            and self.installed_marketing_version == marketing_version
            and self.installed_build_version == build_version
        )


def parse_args() -> argparse.Namespace:
    project_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=project_root)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--mac-app", type=Path)
    parser.add_argument(
        "--json-output",
        type=Path,
        help="Write the readiness report; refuses to overwrite an existing file.",
    )
    parser.add_argument(
        "--create-record",
        type=Path,
        help="Create an incomplete record template; refuses to overwrite an existing file.",
    )
    parser.add_argument("--validate-record", type=Path)
    parser.add_argument(
        "--require-ready",
        action="store_true",
        help="Exit nonzero unless device acceptance and distribution prerequisites are ready.",
    )
    return parser.parse_args()


def run(command: list[str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(command, check=False, capture_output=True)


def signing_identity_kinds(output: str) -> dict[str, int]:
    names = re.findall(r'"([^"]+)"', output)
    return {
        "development": sum(name.startswith("Apple Development:") for name in names),
        "ios_distribution": sum(
            name.startswith(("Apple Distribution:", "iPhone Distribution:"))
            for name in names
        ),
        "mac_distribution": sum(
            name.startswith(("Apple Distribution:", "3rd Party Mac Developer Application:"))
            for name in names
        ),
    }


def inspect_signing_identities() -> tuple[dict[str, int], str | None]:
    process = run(["security", "find-identity", "-v", "-p", "codesigning"])
    output = (process.stdout + process.stderr).decode("utf-8", errors="replace")
    if process.returncode != 0:
        return {"development": 0, "ios_distribution": 0, "mac_distribution": 0}, output.strip()
    return signing_identity_kinds(output), None


def summarize_device(
    raw: dict[str, Any],
    *,
    installed_marketing_version: str | None = None,
    installed_build_version: str | None = None,
    app_inspection_succeeded: bool = False,
) -> DeviceSummary:
    identifier = str(raw.get("identifier", "unknown"))
    device = raw.get("deviceProperties", {}) if isinstance(raw.get("deviceProperties"), dict) else {}
    hardware = raw.get("hardwareProperties", {}) if isinstance(raw.get("hardwareProperties"), dict) else {}
    connection = raw.get("connectionProperties", {}) if isinstance(raw.get("connectionProperties"), dict) else {}
    return DeviceSummary(
        device_ref=hashlib.sha256(identifier.encode("utf-8")).hexdigest()[:12],
        device_type=str(hardware.get("deviceType", "Unknown")),
        marketing_name=str(hardware.get("marketingName", "Unknown model")),
        os_version=str(device.get("osVersionNumber", "Unknown")),
        pairing_state=str(connection.get("pairingState", "unknown")),
        tunnel_state=str(connection.get("tunnelState", "unknown")),
        developer_mode=str(device.get("developerModeStatus", "unknown")),
        ddi_services_available=bool(device.get("ddiServicesAvailable", False)),
        installed_marketing_version=installed_marketing_version,
        installed_build_version=installed_build_version,
        app_inspection_succeeded=app_inspection_succeeded,
    )


def parse_devicectl_payload(
    payload: dict[str, Any],
    installed_apps: dict[str, tuple[str | None, str | None, bool]] | None = None,
) -> list[DeviceSummary]:
    result = payload.get("result", {})
    raw_devices = result.get("devices", []) if isinstance(result, dict) else []
    if not isinstance(raw_devices, list):
        raise ValueError("devicectl JSON result.devices is not a list")
    app_versions = installed_apps or {}
    summaries: list[DeviceSummary] = []
    for raw in raw_devices:
        if not isinstance(raw, dict):
            continue
        identifier = str(raw.get("identifier", "unknown"))
        marketing_version, build_version, inspection_succeeded = app_versions.get(
            identifier,
            (None, None, False),
        )
        summaries.append(
            summarize_device(
                raw,
                installed_marketing_version=marketing_version,
                installed_build_version=build_version,
                app_inspection_succeeded=inspection_succeeded,
            )
        )
    return summaries


def parse_installed_app_payload(
    payload: dict[str, Any],
    *,
    bundle_id: str = EXPECTED_BUNDLE_ID,
) -> tuple[str | None, str | None]:
    result = payload.get("result", {})
    apps = result.get("apps", []) if isinstance(result, dict) else []
    if not isinstance(apps, list):
        raise ValueError("devicectl JSON result.apps is not a list")
    matches = [
        app for app in apps
        if isinstance(app, dict) and app.get("bundleIdentifier") == bundle_id
    ]
    if not matches:
        return None, None
    if len(matches) != 1:
        raise ValueError("devicectl returned multiple installed apps for the expected bundle")
    app = matches[0]
    marketing_version = app.get("version")
    build_version = app.get("bundleVersion")
    return (
        str(marketing_version) if marketing_version is not None else None,
        str(build_version) if build_version is not None else None,
    )


def inspect_installed_app(identifier: str) -> tuple[str | None, str | None, bool]:
    with tempfile.TemporaryDirectory(prefix="gunnaire-installed-app-") as temp_dir:
        output_path = Path(temp_dir) / "apps.json"
        process = run(
            [
                "xcrun",
                "devicectl",
                "device",
                "info",
                "apps",
                "--device",
                identifier,
                "--timeout",
                "15",
                "--json-output",
                str(output_path),
                "--quiet",
            ]
        )
        if process.returncode != 0 or not output_path.is_file():
            return None, None, False
        try:
            payload = json.loads(output_path.read_text(encoding="utf-8"))
            marketing_version, build_version = parse_installed_app_payload(payload)
            return marketing_version, build_version, True
        except (OSError, ValueError, json.JSONDecodeError):
            return None, None, False


def inspect_devices() -> tuple[list[DeviceSummary], str | None]:
    with tempfile.TemporaryDirectory(prefix="gunnaire-device-acceptance-") as temp_dir:
        output_path = Path(temp_dir) / "devices.json"
        process = run(
            [
                "xcrun",
                "devicectl",
                "list",
                "devices",
                "--json-output",
                str(output_path),
                "--quiet",
            ]
        )
        if process.returncode != 0 or not output_path.is_file():
            detail = (process.stdout + process.stderr).decode("utf-8", errors="replace").strip()
            return [], detail or "devicectl did not produce JSON output"
        try:
            payload = json.loads(output_path.read_text(encoding="utf-8"))
            result = payload.get("result", {})
            raw_devices = result.get("devices", []) if isinstance(result, dict) else []
            if not isinstance(raw_devices, list):
                raise ValueError("devicectl JSON result.devices is not a list")
            installed_apps: dict[str, tuple[str | None, str | None, bool]] = {}
            for raw in raw_devices:
                if not isinstance(raw, dict):
                    continue
                identifier = str(raw.get("identifier", ""))
                if not identifier:
                    continue
                summary = summarize_device(raw)
                if summary.is_available:
                    installed_apps[identifier] = inspect_installed_app(identifier)
            return parse_devicectl_payload(payload, installed_apps), None
        except (OSError, ValueError, json.JSONDecodeError) as error:
            return [], str(error)


def check_item(identifier: str, status: str, detail: str) -> dict[str, str]:
    return {"id": identifier, "status": status, "detail": detail}


def build_readiness_report(
    *,
    marketing_version: str,
    build_version: str,
    archive: Path | None,
    mac_app: Path | None,
    identities: dict[str, int],
    devices: Iterable[DeviceSummary],
    signing_error: str | None = None,
    device_error: str | None = None,
) -> dict[str, Any]:
    device_list = list(devices)
    available_ipads = [device for device in device_list if device.device_type == "iPad" and device.is_available]
    available_iphones = [device for device in device_list if device.device_type == "iPhone" and device.is_available]
    current_ipads = [
        device for device in available_ipads
        if device.has_current_build(marketing_version, build_version)
    ]
    current_iphones = [
        device for device in available_iphones
        if device.has_current_build(marketing_version, build_version)
    ]
    checks = [
        check_item(
            "current-ios-archive",
            "pass" if archive is not None and archive.is_dir() else "blocked",
            str(archive) if archive is not None and archive.is_dir() else "Exact current iOS archive is missing.",
        ),
        check_item(
            "current-mac-app",
            "pass" if mac_app is not None and mac_app.is_dir() else "blocked",
            str(mac_app) if mac_app is not None and mac_app.is_dir() else "Exact current Mac app is missing.",
        ),
        check_item(
            "development-signing",
            "pass" if identities.get("development", 0) > 0 else "blocked",
            signing_error or f"{identities.get('development', 0)} Apple Development identity available.",
        ),
        check_item(
            "ios-distribution-signing",
            "pass" if identities.get("ios_distribution", 0) > 0 else "blocked",
            "Apple Distribution identity is available."
            if identities.get("ios_distribution", 0) > 0
            else "Apple Distribution private key is not available on this Mac.",
        ),
        check_item(
            "mac-distribution-signing",
            "pass" if identities.get("mac_distribution", 0) > 0 else "blocked",
            "Mac distribution identity is available."
            if identities.get("mac_distribution", 0) > 0
            else "Mac distribution private key/profile selection remains required.",
        ),
        check_item(
            "physical-ipad",
            "pass" if current_ipads else "blocked",
            f"{len(current_ipads)} paired development iPad has exact build {build_version} installed. Unlock and normal launch remain separate acceptance steps."
            if current_ipads
            else (
                f"{len(available_ipads)} paired development iPad detected, but exact build {build_version} is not confirmed installed."
                if available_ipads
                else device_error or "No paired, connected, Developer Mode iPad with DDI services is available."
            ),
        ),
        check_item(
            "physical-iphone",
            "pass" if current_iphones else "blocked",
            f"{len(current_iphones)} paired development iPhone has exact build {build_version} installed. Unlock and normal launch remain separate acceptance steps."
            if current_iphones
            else (
                f"{len(available_iphones)} paired development iPhone detected, but exact build {build_version} is not confirmed installed."
                if available_iphones
                else device_error or "No paired, connected, Developer Mode iPhone with DDI services is available."
            ),
        ),
    ]
    statuses = {item["id"]: item["status"] for item in checks}
    device_acceptance_ready = all(
        statuses[identifier] == "pass"
        for identifier in (
            "current-ios-archive",
            "current-mac-app",
            "development-signing",
            "physical-ipad",
            "physical-iphone",
        )
    )
    app_store_export_ready = all(
        statuses[identifier] == "pass"
        for identifier in ("current-ios-archive", "ios-distribution-signing")
    )
    mac_distribution_ready = all(
        statuses[identifier] == "pass"
        for identifier in ("current-mac-app", "mac-distribution-signing")
    )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAtUTC": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "application": {
            "bundleID": EXPECTED_BUNDLE_ID,
            "teamID": EXPECTED_TEAM_ID,
            "marketingVersion": marketing_version,
            "buildVersion": build_version,
        },
        "signingIdentityCounts": identities,
        "devices": [
            {
                **asdict(device),
                "is_available": device.is_available,
                "is_current_build": device.has_current_build(marketing_version, build_version),
            }
            for device in device_list
        ],
        "checks": checks,
        "readiness": {
            "signedDeviceAcceptance": device_acceptance_ready,
            "appStoreExport": app_store_export_ready,
            "macDistribution": mac_distribution_ready,
        },
    }


def acceptance_record_template(marketing_version: str, build_version: str) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "application": {
            "bundleID": EXPECTED_BUNDLE_ID,
            "teamID": EXPECTED_TEAM_ID,
            "marketingVersion": marketing_version,
            "buildVersion": build_version,
        },
        "run": {
            "startedAtUTC": "",
            "completedAtUTC": "",
            "operator": "",
            "cloudKitEnvironment": "Development",
            "qboEnvironment": "sandbox",
            "productionMutationAuthorizationReference": "",
            "productionPromotionApprovalReference": "",
            "evidenceContainsCustomerOrPaymentData": False,
            "notes": "",
        },
        "devices": {
            "iPad": {"model": "", "osVersion": ""},
            "iPhone": {"model": "", "osVersion": ""},
            "Mac": {"model": "", "osVersion": ""},
        },
        "scenarios": [
            {
                "id": scenario.identifier,
                "title": scenario.title,
                "expectedEvidence": scenario.expected_evidence,
                "status": "not_run",
                "evidence": [],
                "notes": "",
            }
            for scenario in REQUIRED_SCENARIOS
        ],
    }


def parse_timestamp(value: Any, field_name: str, errors: list[str]) -> datetime | None:
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
    return parsed


def validate_acceptance_record(
    record: dict[str, Any],
    *,
    marketing_version: str,
    build_version: str,
    now: datetime | None = None,
) -> list[str]:
    errors: list[str] = []
    if record.get("schemaVersion") != SCHEMA_VERSION:
        errors.append(f"schemaVersion must equal {SCHEMA_VERSION}")
    application = record.get("application", {})
    if not isinstance(application, dict):
        application = {}
        errors.append("application must be an object")
    expected_application = {
        "bundleID": EXPECTED_BUNDLE_ID,
        "teamID": EXPECTED_TEAM_ID,
        "marketingVersion": marketing_version,
        "buildVersion": build_version,
    }
    for key, expected in expected_application.items():
        if application.get(key) != expected:
            errors.append(f"application.{key} must equal {expected}")

    run_data = record.get("run", {})
    if not isinstance(run_data, dict):
        run_data = {}
        errors.append("run must be an object")
    if not isinstance(run_data.get("operator"), str) or not run_data.get("operator", "").strip():
        errors.append("run.operator is required")
    started = parse_timestamp(run_data.get("startedAtUTC"), "run.startedAtUTC", errors)
    completed = parse_timestamp(run_data.get("completedAtUTC"), "run.completedAtUTC", errors)
    current = now or datetime.now(timezone.utc)
    if started and completed and completed < started:
        errors.append("run.completedAtUTC cannot precede run.startedAtUTC")
    if completed and completed > current.astimezone(completed.tzinfo):
        errors.append("run.completedAtUTC cannot be in the future")
    if run_data.get("evidenceContainsCustomerOrPaymentData") is not False:
        errors.append("run.evidenceContainsCustomerOrPaymentData must be false")

    cloudkit_environment = run_data.get("cloudKitEnvironment")
    if cloudkit_environment not in {"Development", "Production"}:
        errors.append("run.cloudKitEnvironment must be Development or Production")
    if cloudkit_environment == "Production" and not str(
        run_data.get("productionPromotionApprovalReference", "")
    ).strip():
        errors.append("Production CloudKit evidence requires productionPromotionApprovalReference")
    qbo_environment = run_data.get("qboEnvironment")
    if qbo_environment not in {"sandbox", "production"}:
        errors.append("run.qboEnvironment must be sandbox or production")
    if qbo_environment == "production" and not str(
        run_data.get("productionMutationAuthorizationReference", "")
    ).strip():
        errors.append("Production QBO evidence requires productionMutationAuthorizationReference")

    devices = record.get("devices", {})
    if not isinstance(devices, dict):
        devices = {}
        errors.append("devices must be an object")
    for kind in ("iPad", "iPhone", "Mac"):
        detail = devices.get(kind, {})
        if not isinstance(detail, dict):
            errors.append(f"devices.{kind} must be an object")
            continue
        for field_name in ("model", "osVersion"):
            if not isinstance(detail.get(field_name), str) or not detail.get(field_name, "").strip():
                errors.append(f"devices.{kind}.{field_name} is required")

    scenarios = record.get("scenarios", [])
    if not isinstance(scenarios, list):
        scenarios = []
        errors.append("scenarios must be a list")
    by_id: dict[str, dict[str, Any]] = {}
    for index, scenario in enumerate(scenarios):
        if not isinstance(scenario, dict):
            errors.append(f"scenarios[{index}] must be an object")
            continue
        identifier = scenario.get("id")
        if not isinstance(identifier, str) or not identifier:
            errors.append(f"scenarios[{index}].id is required")
            continue
        if identifier in by_id:
            errors.append(f"scenario {identifier} is duplicated")
            continue
        by_id[identifier] = scenario
    for required in REQUIRED_SCENARIOS:
        scenario = by_id.get(required.identifier)
        if scenario is None:
            errors.append(f"required scenario {required.identifier} is missing")
            continue
        status = scenario.get("status")
        if status != "passed":
            errors.append(f"scenario {required.identifier} must be passed, found {status!r}")
        evidence = scenario.get("evidence")
        if not isinstance(evidence, list) or not evidence or not all(
            isinstance(item, str) and item.strip() for item in evidence
        ):
            errors.append(f"scenario {required.identifier} requires at least one evidence reference")
    return errors


def write_new_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2, sort_keys=False)
        stream.write("\n")


def print_report(report: dict[str, Any]) -> None:
    application = report["application"]
    print(
        f"GunnAire signed-device readiness — {application['marketingVersion']} "
        f"({application['buildVersion']})"
    )
    for item in report["checks"]:
        print(f"{item['status'].upper():7} {item['id']}: {item['detail']}")
    for device in report["devices"]:
        if device["is_current_build"]:
            state = f"exact build {application['buildVersion']} installed; launch not yet accepted"
        elif device["is_available"]:
            state = "development connection ready; exact build missing or unverified"
        else:
            state = "development connection unavailable"
        print(
            f"DEVICE  {device['device_ref']} — {device['marketing_name']} "
            f"{device['os_version']} — {state}"
        )
    readiness = report["readiness"]
    print(f"SIGNED DEVICE ACCEPTANCE READY: {'YES' if readiness['signedDeviceAcceptance'] else 'NO'}")
    print(f"APP STORE EXPORT READY: {'YES' if readiness['appStoreExport'] else 'NO'}")
    print(f"MAC DISTRIBUTION READY: {'YES' if readiness['macDistribution'] else 'NO'}")


def main() -> int:
    args = parse_args()
    project_file = args.project_root / "GunnAire Ops.xcodeproj" / "project.pbxproj"
    marketing_version, build_version = release_preflight.source_versions(project_file)
    archive = args.archive or release_preflight.find_archive(marketing_version, build_version)
    mac_app = args.mac_app or release_preflight.find_mac_app(build_version)
    identities, signing_error = inspect_signing_identities()
    devices, device_error = inspect_devices()
    report = build_readiness_report(
        marketing_version=marketing_version,
        build_version=build_version,
        archive=archive,
        mac_app=mac_app,
        identities=identities,
        devices=devices,
        signing_error=signing_error,
        device_error=device_error,
    )
    print_report(report)

    try:
        if args.json_output:
            write_new_json(args.json_output, report)
            print(f"WROTE   readiness report: {args.json_output}")
        if args.create_record:
            write_new_json(
                args.create_record,
                acceptance_record_template(marketing_version, build_version),
            )
            print(f"WROTE   incomplete acceptance template: {args.create_record}")
    except FileExistsError as error:
        print(f"ERROR   refusing to overwrite existing file: {error.filename}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"ERROR   evidence file could not be written: {error}", file=sys.stderr)
        return 2

    if args.validate_record:
        try:
            record = json.loads(args.validate_record.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"ERROR   acceptance record could not be read: {error}", file=sys.stderr)
            return 2
        if not isinstance(record, dict):
            print("ERROR   acceptance record must be a JSON object", file=sys.stderr)
            return 2
        errors = validate_acceptance_record(
            record,
            marketing_version=marketing_version,
            build_version=build_version,
        )
        if errors:
            for error in errors:
                print(f"INCOMPLETE  {error}")
            print(f"ACCEPTANCE RECORD: INCOMPLETE ({len(errors)} issue(s))")
            return 1
        print("ACCEPTANCE RECORD: PASSED")

    if args.require_ready and not all(report["readiness"].values()):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
