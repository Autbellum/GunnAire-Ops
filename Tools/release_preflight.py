#!/usr/bin/env python3
"""Read-only GunnAire Ops release preflight.

The local checks validate the exact Xcode source/archive and retained CloudKit
schema exports.  ``--online`` adds non-mutating production health, malformed
Apple-envelope, and OAuth callback probes.  This utility never deploys code,
changes Apple/Intuit configuration, or sends an accounting mutation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any


EXPECTED_BUNDLE_ID = "com.gunnaire.businesssuite"
EXPECTED_TEAM_ID = "7C4B3RR7RD"
EXPECTED_ICLOUD_CONTAINER = "iCloud.com.gunnaire.businesssuite"
EXPECTED_ASSOCIATED_DOMAIN = "applinks:gunnaire.com"
EXPECTED_BACKEND_URL = "https://gunnaire-api.onrender.com"
EXPECTED_QBO_REDIRECT = "https://gunnaire.com/wp-json/ga/v1/qbo/oauth/callback"
EXPECTED_QBO_CALLBACK_SCHEME = "gunnaireops"
EXPECTED_CLOUDKIT_V13_ADDITIONS = {
    "CD_Estimate": {
        "CD_salesTaxAmount": ("DOUBLE", "QUERYABLE", "SORTABLE"),
        "CD_taxCalculatedAt": ("TIMESTAMP", "QUERYABLE", "SORTABLE"),
        "CD_taxCalculationStatusRawValue": (
            "STRING",
            "QUERYABLE",
            "SEARCHABLE",
            "SORTABLE",
        ),
    },
    "CD_Invoice": {
        "CD_salesTaxAmount": ("DOUBLE", "QUERYABLE", "SORTABLE"),
        "CD_taxCalculatedAt": ("TIMESTAMP", "QUERYABLE", "SORTABLE"),
        "CD_taxCalculationStatusRawValue": (
            "STRING",
            "QUERYABLE",
            "SEARCHABLE",
            "SORTABLE",
        ),
    },
}
EXPECTED_CLOUDKIT_V14_ADDITIONS = {
    **EXPECTED_CLOUDKIT_V13_ADDITIONS,
    "CD_Invoice": {
        **EXPECTED_CLOUDKIT_V13_ADDITIONS["CD_Invoice"],
        "CD_dueDate": ("TIMESTAMP", "QUERYABLE", "SORTABLE"),
    },
}
EXPECTED_CLOUDKIT_V15_ADDITIONS = {
    **EXPECTED_CLOUDKIT_V14_ADDITIONS,
    "CD_InventoryMovement": {
        "CD_itemSKU": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
    },
    "CD_Item": {
        "CD_defaultInventoryLocation": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_flatRateAssemblyJSON": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_itemDescription": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_preferredVendorName": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_preferredVendorQuickBooksID": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_purchaseCost": ("DOUBLE", "QUERYABLE", "SORTABLE"),
        "CD_purchaseDescription": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_purchaseURL": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_quickBooksID": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_quickBooksLastSyncedAt": ("TIMESTAMP", "QUERYABLE", "SORTABLE"),
        "CD_quickBooksSyncDetail": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_reorderPoint": ("DOUBLE", "QUERYABLE", "SORTABLE"),
        "CD_sku": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_vendorPartNumber": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
    },
}


@dataclass
class Results:
    passed: int = 0
    warnings: int = 0
    failures: list[str] = field(default_factory=list)

    def pass_(self, message: str) -> None:
        self.passed += 1
        print(f"PASS  {message}")

    def warn(self, message: str) -> None:
        self.warnings += 1
        print(f"WARN  {message}")

    def fail(self, message: str) -> None:
        self.failures.append(message)
        print(f"FAIL  {message}")

    def require(self, condition: bool, success: str, failure: str) -> bool:
        if condition:
            self.pass_(success)
            return True
        self.fail(failure)
        return False


def parse_args() -> argparse.Namespace:
    script_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=script_root)
    parser.add_argument(
        "--archive",
        type=Path,
        help="Exact .xcarchive to validate; newest matching Current Source archive is used by default.",
    )
    parser.add_argument("--cloudkit-development-export", type=Path)
    parser.add_argument("--cloudkit-production-export", type=Path)
    parser.add_argument(
        "--app-store-profile",
        type=Path,
        help="Installed App Store .mobileprovision; a matching Xcode-managed profile is discovered by default.",
    )
    parser.add_argument(
        "--mac-app",
        type=Path,
        help="Exact current-source Mac Catalyst .app; the standard derived-data artifact is discovered by default.",
    )
    parser.add_argument(
        "--mac-result",
        type=Path,
        help="Mac Catalyst build .xcresult; the standard result bundle is discovered by default.",
    )
    parser.add_argument(
        "--online",
        action="store_true",
        help="Also probe production health, Apple notification routing, and the QBO callback.",
    )
    parser.add_argument(
        "--require-app-store-signing",
        action="store_true",
        help="Treat a development-signed archive as a failure instead of a release warning.",
    )
    return parser.parse_args()


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(command, check=check, capture_output=True)


def load_plist(path: Path) -> dict[str, Any]:
    with path.open("rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"{path} is not a dictionary property list")
    return value


def source_versions(project_file: Path) -> tuple[str, str]:
    source = project_file.read_text(encoding="utf-8")
    builds = set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", source))
    versions = set(re.findall(r"MARKETING_VERSION = ([^;]+);", source))
    if len(builds) != 1 or len(versions) != 1:
        raise ValueError(
            f"Expected one build/version across targets, found builds={sorted(builds)} versions={sorted(versions)}"
        )
    return versions.pop().strip('"'), builds.pop().strip('"')


def source_backend_version(backend_file: Path) -> str:
    match = re.search(
        r'^SERVICE_VERSION\s*=\s*"([^"]+)"',
        backend_file.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if match is None:
        raise ValueError("Backend SERVICE_VERSION is missing")
    return match.group(1)


def find_archive(marketing_version: str, build_version: str) -> Path | None:
    releases = Path.home() / "Downloads" / "GunnAire Ops Releases"
    if not releases.is_dir():
        return None
    pattern = f"GunnAire Ops {marketing_version} ({build_version} Current Source).xcarchive"
    candidates = list(releases.rglob(pattern))
    return max(candidates, key=lambda path: path.stat().st_mtime) if candidates else None


def find_app_store_profile() -> Path | None:
    profiles_root = (
        Path.home()
        / "Library"
        / "Developer"
        / "Xcode"
        / "UserData"
        / "Provisioning Profiles"
    )
    if not profiles_root.is_dir():
        return None
    candidates: list[Path] = []
    for suffix in ("*.mobileprovision", "*.provisionprofile"):
        for path in profiles_root.glob(suffix):
            try:
                profile = extract_profile(path)
            except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError):
                continue
            entitlements = profile.get("Entitlements", {})
            if (
                entitlements.get("application-identifier")
                == f"{EXPECTED_TEAM_ID}.{EXPECTED_BUNDLE_ID}"
                and entitlements.get("get-task-allow") is False
            ):
                candidates.append(path)
    return max(candidates, key=lambda path: path.stat().st_mtime) if candidates else None


def find_mac_app(build_version: str) -> Path | None:
    releases = Path.home() / "Downloads" / "GunnAire Ops Releases"
    retained_name = f"GunnAire Ops 1.0 ({build_version} Current Source Mac Catalyst).app"
    retained = list(releases.rglob(retained_name)) if releases.is_dir() else []
    if retained:
        return max(retained, key=lambda path: path.stat().st_mtime)
    temporary = (
        Path("/tmp")
        / f"GunnAireOps-mac-release-{build_version}"
        / "Build"
        / "Products"
        / "Release-maccatalyst"
        / "GunnAire Ops.app"
    )
    return temporary if temporary.is_dir() else None


def find_mac_result(build_version: str) -> Path | None:
    releases = Path.home() / "Downloads" / "GunnAire Ops Releases"
    retained_name = f"GunnAire Ops 1.0 ({build_version} Current Source Mac Catalyst).xcresult"
    retained = list(releases.rglob(retained_name)) if releases.is_dir() else []
    if retained:
        return max(retained, key=lambda path: path.stat().st_mtime)
    temporary = Path("/tmp") / f"GunnAireOps-mac-release-{build_version}.xcresult"
    return temporary if temporary.is_dir() else None


def extract_codesign_entitlements(app_path: Path) -> dict[str, Any]:
    process = run(["codesign", "-d", "--entitlements", ":-", str(app_path)], check=False)
    payload = process.stdout if b"<?xml" in process.stdout else process.stderr
    start = payload.find(b"<?xml")
    end = payload.rfind(b"</plist>")
    if start < 0:
        raise ValueError((process.stdout + process.stderr).decode("utf-8", errors="replace").strip())
    if end < start:
        raise ValueError("codesign entitlement property list is incomplete")
    return plistlib.loads(payload[start : end + len(b"</plist>")])


def extract_profile(profile_path: Path) -> dict[str, Any]:
    process = run(["security", "cms", "-D", "-i", str(profile_path)])
    return plistlib.loads(process.stdout)


def binary_uuids(path: Path) -> set[str]:
    output = run(["dwarfdump", "--uuid", str(path)]).stdout.decode("utf-8")
    return set(re.findall(r"UUID: ([0-9A-F-]+)", output))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def is_future_datetime(value: Any) -> bool:
    return isinstance(value, datetime) and value > datetime.now(tz=value.tzinfo)


def check_source(root: Path, results: Results) -> tuple[str, str, str]:
    try:
        marketing_version, build_version = source_versions(
            root / "GunnAire Ops.xcodeproj" / "project.pbxproj"
        )
        backend_version = source_backend_version(root / "Backend" / "gunnaire_backend.py")
    except (OSError, ValueError) as error:
        results.fail(f"Source version inspection failed: {error}")
        return "", "", ""

    results.pass_(f"Source version is {marketing_version} ({build_version})")
    results.pass_(f"Backend source version is {backend_version}")

    for relative in (
        Path("GunnAire Ops") / "GunnAire Ops.entitlements",
        Path("GunnAire Ops") / "PrivacyInfo.xcprivacy",
        Path("GunnAire Ops") / "Info.plist",
    ):
        process = run(["plutil", "-lint", str(root / relative)], check=False)
        results.require(
            process.returncode == 0,
            f"{relative} is a valid property list",
            f"{relative} failed property-list validation",
        )

    try:
        source_entitlements = load_plist(root / "GunnAire Ops" / "GunnAire Ops.entitlements")
        results.require(
            source_entitlements.get("com.apple.developer.applesignin") == ["Default"],
            "Source declares Sign in with Apple",
            "Source is missing the Sign in with Apple entitlement",
        )
        results.require(
            EXPECTED_ICLOUD_CONTAINER
            in source_entitlements.get("com.apple.developer.icloud-container-identifiers", []),
            "Source declares the GunnAire CloudKit container",
            "Source is missing the GunnAire CloudKit container",
        )
        results.require(
            source_entitlements.get("com.apple.developer.icloud-services") == ["CloudKit"],
            "Source declares CloudKit service",
            "Source CloudKit service entitlement is incorrect",
        )
        results.require(
            EXPECTED_ASSOCIATED_DOMAIN
            in source_entitlements.get("com.apple.developer.associated-domains", []),
            "Source declares the GunnAire associated domain",
            "Source associated-domain entitlement is missing",
        )
        results.require(
            source_entitlements.get("aps-environment") == "development",
            "Source declares Push Notifications for development signing",
            "Source push entitlement is missing or unexpected",
        )
    except (OSError, ValueError) as error:
        results.fail(f"Source entitlement inspection failed: {error}")

    return marketing_version, build_version, backend_version


def check_archive(
    archive: Path,
    marketing_version: str,
    build_version: str,
    require_app_store_signing: bool,
    results: Results,
) -> None:
    app_path = archive / "Products" / "Applications" / "GunnAire Ops.app"
    binary_path = app_path / "GunnAire Ops"
    dsym_binary = (
        archive
        / "dSYMs"
        / "GunnAire Ops.app.dSYM"
        / "Contents"
        / "Resources"
        / "DWARF"
        / "GunnAire Ops"
    )
    required_paths = (
        archive / "Info.plist",
        app_path / "Info.plist",
        app_path / "PrivacyInfo.xcprivacy",
        app_path / "embedded.mobileprovision",
        binary_path,
        dsym_binary,
    )
    if not results.require(
        archive.is_dir() and all(path.exists() for path in required_paths),
        f"Archive contains the expected app, profile, binary, privacy manifest, and dSYM: {archive}",
        f"Archive is missing or incomplete: {archive}",
    ):
        return

    verification = run(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_path)],
        check=False,
    )
    results.require(
        verification.returncode == 0,
        "Archive passes strict code-signature verification",
        "Archive failed strict code-signature verification",
    )
    privacy = run(["plutil", "-lint", str(app_path / "PrivacyInfo.xcprivacy")], check=False)
    results.require(
        privacy.returncode == 0,
        "Archived privacy manifest is valid",
        "Archived privacy manifest is invalid",
    )

    try:
        archive_info = load_plist(archive / "Info.plist")
        app_info = load_plist(app_path / "Info.plist")
        properties = archive_info.get("ApplicationProperties", {})
        results.require(
            app_info.get("CFBundleIdentifier") == EXPECTED_BUNDLE_ID,
            f"Archived bundle identifier is {EXPECTED_BUNDLE_ID}",
            f"Archived bundle identifier is {app_info.get('CFBundleIdentifier')!r}",
        )
        results.require(
            app_info.get("CFBundleShortVersionString") == marketing_version
            and app_info.get("CFBundleVersion") == build_version,
            f"Archive exactly matches source version {marketing_version} ({build_version})",
            "Archive version/build does not match the source",
        )
        results.require(
            set(app_info.get("UIDeviceFamily", [])) == {1, 2},
            "Archive supports iPhone and iPad device families",
            f"Unexpected archived device families: {app_info.get('UIDeviceFamily')!r}",
        )
        expected_phone_orientations = {
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        }
        expected_ipad_orientations = expected_phone_orientations | {
            "UIInterfaceOrientationPortraitUpsideDown"
        }
        results.require(
            set(app_info.get("UISupportedInterfaceOrientations", []))
            == expected_phone_orientations
            and set(app_info.get("UISupportedInterfaceOrientations~ipad", []))
            == expected_ipad_orientations,
            "Archive supports portrait and landscape operation, including all iPad orientations",
            "Archived iPhone/iPad orientation support is incomplete",
        )
        results.require(
            app_info.get("ITSAppUsesNonExemptEncryption") is False,
            "Archive declares no non-exempt encryption for export-compliance routing",
            "Archived export-compliance declaration is missing or unexpected",
        )

        expected_settings = {
            "GUNNAIRE_BACKEND_BASE_URL": EXPECTED_BACKEND_URL,
            "GUNNAIRE_BACKEND_AUTH_MODE": "google-id-token",
            "GUNNAIRE_BACKEND_API_TOKEN": "",
            "QB_ENVIRONMENT": "production",
            "QB_REDIRECT_URI": EXPECTED_QBO_REDIRECT,
            "QB_CALLBACK_SCHEME": EXPECTED_QBO_CALLBACK_SCHEME,
            "QB_ENABLE_PAYMENTS_SCOPE": "true",
        }
        mismatches = {
            key: app_info.get(key)
            for key, expected in expected_settings.items()
            if app_info.get(key) != expected
        }
        results.require(
            not mismatches,
            "Archive uses HTTPS business identity, an empty shared token, and production QBO settings",
            f"Archived production settings are incorrect: {mismatches}",
        )
        results.require(
            bool(str(app_info.get("QB_CLIENT_ID", "")).strip()),
            "Archive contains a non-secret QBO client identifier",
            "Archive is missing the QBO client identifier",
        )
        results.require(
            bool(str(app_info.get("GOOGLE_CLIENT_ID", "")).strip())
            and app_info.get("GOOGLE_CALLBACK_SCHEME")
            == app_info.get("GOOGLE_REVERSED_CLIENT_ID"),
            "Archive contains matching Google OAuth client/callback identifiers",
            "Archived Google OAuth client/callback identifiers are incomplete or inconsistent",
        )

        entitlements = extract_codesign_entitlements(app_path)
        profile = extract_profile(app_path / "embedded.mobileprovision")
        profile_entitlements = profile.get("Entitlements", {})
        archived_privacy = load_plist(app_path / "PrivacyInfo.xcprivacy")
        collected_types = {
            row.get("NSPrivacyCollectedDataType")
            for row in archived_privacy.get("NSPrivacyCollectedDataTypes", [])
            if isinstance(row, dict)
        }
        results.require(
            {
                "NSPrivacyCollectedDataTypeDeviceID",
                "NSPrivacyCollectedDataTypePaymentInfo",
                "NSPrivacyCollectedDataTypeOtherFinancialInfo",
            }.issubset(collected_types),
            "Privacy manifest covers device, payment, and financial app-functionality data",
            "Privacy manifest omits a release-critical device/payment/financial data category",
        )
        expected_application_id = f"{EXPECTED_TEAM_ID}.{EXPECTED_BUNDLE_ID}"
        checks = (
            (
                entitlements.get("application-identifier") == expected_application_id,
                "Archive application identifier matches the Apple team and bundle",
                "Archive application identifier does not match the Apple team and bundle",
            ),
            (
                entitlements.get("com.apple.developer.applesignin") == ["Default"],
                "Archive includes Sign in with Apple",
                "Archive is missing Sign in with Apple",
            ),
            (
                EXPECTED_ICLOUD_CONTAINER
                in entitlements.get("com.apple.developer.icloud-container-identifiers", []),
                "Archive includes the GunnAire CloudKit container",
                "Archive is missing the GunnAire CloudKit container",
            ),
            (
                entitlements.get("com.apple.developer.icloud-services") == ["CloudKit"],
                "Archive includes the CloudKit service entitlement",
                "Archive CloudKit service entitlement is missing or unexpected",
            ),
            (
                EXPECTED_ASSOCIATED_DOMAIN
                in entitlements.get("com.apple.developer.associated-domains", []),
                "Archive includes the GunnAire associated domain",
                "Archive is missing the GunnAire associated domain",
            ),
            (
                entitlements.get("aps-environment") in {"development", "production"},
                f"Archive includes {entitlements.get('aps-environment')} APNs",
                "Archive is missing the APNs entitlement",
            ),
            (
                profile_entitlements.get("application-identifier") == expected_application_id,
                "Embedded profile matches the GunnAire application identifier",
                "Embedded profile has an unexpected application identifier",
            ),
        )
        for condition, success, failure in checks:
            results.require(condition, success, failure)

        results.require(
            is_future_datetime(profile.get("ExpirationDate"))
            and EXPECTED_TEAM_ID in profile.get("TeamIdentifier", []),
            f"Embedded profile is current and belongs to Apple team {EXPECTED_TEAM_ID}",
            "Embedded profile is expired or belongs to an unexpected Apple team",
        )

        signing_identity = str(properties.get("SigningIdentity", ""))
        uploadable = (
            signing_identity.startswith("Apple Distribution")
            and entitlements.get("get-task-allow") is False
            and entitlements.get("aps-environment") == "production"
        )
        profile_id = profile.get("UUID", "unknown")
        if uploadable:
            results.pass_(f"Archive is App Store distribution signed with profile {profile_id}")
        elif require_app_store_signing:
            results.fail(
                f"Archive is not App Store uploadable: identity={signing_identity!r}, profile={profile_id}"
            )
        else:
            results.warn(
                f"Archive is correctly validated but development signed with profile {profile_id}; "
                "an Apple Distribution private key is still required for upload"
            )
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        results.fail(f"Archive metadata/entitlement inspection failed: {error}")

    try:
        app_uuids = binary_uuids(binary_path)
        dsym_uuids = binary_uuids(dsym_binary)
        results.require(
            bool(app_uuids) and app_uuids == dsym_uuids,
            f"App and dSYM UUIDs match: {', '.join(sorted(app_uuids))}",
            f"App/dSYM UUID mismatch: app={sorted(app_uuids)} dSYM={sorted(dsym_uuids)}",
        )
        results.pass_(f"Release binary SHA-256 is {sha256(binary_path)}")
    except (OSError, subprocess.CalledProcessError) as error:
        results.fail(f"Binary/dSYM inspection failed: {error}")

    strings_process = run(["strings", str(binary_path)], check=False)
    strings_text = strings_process.stdout.decode("utf-8", errors="replace")
    forbidden = [marker for marker in ("-uiTest", "bootstrap", "localhost", "127.0.0.1") if marker in strings_text]
    results.require(
        strings_process.returncode == 0 and not forbidden,
        "Release binary contains no UI-test, bootstrap, or local-host markers",
        f"Release binary contains forbidden markers: {forbidden}",
    )


def check_app_store_profile(path: Path, results: Results) -> None:
    try:
        profile = extract_profile(path)
        entitlements = profile.get("Entitlements", {})
        expected_application_id = f"{EXPECTED_TEAM_ID}.{EXPECTED_BUNDLE_ID}"
        results.require(
            is_future_datetime(profile.get("ExpirationDate"))
            and EXPECTED_TEAM_ID in profile.get("TeamIdentifier", []),
            f"Installed App Store profile {profile.get('UUID', 'unknown')} is current and belongs to the GunnAire team",
            "Installed App Store profile is expired or belongs to an unexpected team",
        )
        results.require(
            entitlements.get("application-identifier") == expected_application_id
            and entitlements.get("get-task-allow") is False
            and entitlements.get("aps-environment") == "production"
            and entitlements.get("beta-reports-active") is True
            and "ProvisionedDevices" not in profile,
            "App Store profile is distribution-scoped with production APNs and TestFlight reporting",
            "App Store profile has an unexpected distribution, APNs, or device scope",
        )
        cloudkit_environments = entitlements.get(
            "com.apple.developer.icloud-container-environment", []
        )
        results.require(
            entitlements.get("com.apple.developer.applesignin") == ["Default"]
            and EXPECTED_ICLOUD_CONTAINER
            in entitlements.get("com.apple.developer.icloud-container-identifiers", [])
            and "Production" in cloudkit_environments,
            "App Store profile includes Sign in with Apple and Production CloudKit",
            "App Store profile is missing Sign in with Apple or Production CloudKit",
        )
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        results.fail(f"App Store profile inspection failed: {error}")


def check_mac_app(
    app_path: Path,
    marketing_version: str,
    build_version: str,
    require_app_store_signing: bool,
    results: Results,
) -> None:
    binary_path = app_path / "Contents" / "MacOS" / "GunnAire Ops"
    info_path = app_path / "Contents" / "Info.plist"
    privacy_path = app_path / "Contents" / "Resources" / "PrivacyInfo.xcprivacy"
    profile_path = app_path / "Contents" / "embedded.provisionprofile"
    adjacent_dsym_binary = (
        app_path.parent
        / f"{app_path.name}.dSYM"
        / "Contents"
        / "Resources"
        / "DWARF"
        / "GunnAire Ops"
    )
    dsym_candidates = [adjacent_dsym_binary]
    archive_root = app_path.parent.parent.parent
    if archive_root.suffix == ".xcarchive":
        dsym_candidates.append(
            archive_root
            / "dSYMs"
            / f"{app_path.name}.dSYM"
            / "Contents"
            / "Resources"
            / "DWARF"
            / "GunnAire Ops"
        )
    dsym_binary = next(
        (candidate for candidate in dsym_candidates if candidate.exists()),
        adjacent_dsym_binary,
    )
    required_paths = (binary_path, info_path, privacy_path, profile_path, dsym_binary)
    if not results.require(
        app_path.is_dir() and all(path.exists() for path in required_paths),
        f"Mac Catalyst artifact contains the app, profile, binary, privacy manifest, and dSYM: {app_path}",
        f"Mac Catalyst artifact is missing or incomplete: {app_path}",
    ):
        return

    verification = run(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_path)],
        check=False,
    )
    results.require(
        verification.returncode == 0,
        "Mac Catalyst app passes strict code-signature verification",
        "Mac Catalyst app failed strict code-signature verification",
    )
    signature = run(["codesign", "-d", "--verbose=4", str(app_path)], check=False)
    signature_text = (signature.stdout + signature.stderr).decode("utf-8", errors="replace")
    results.require(
        signature.returncode == 0
        and "flags=0x10000(runtime)" in signature_text
        and f"TeamIdentifier={EXPECTED_TEAM_ID}" in signature_text,
        "Mac Catalyst app enables hardened runtime and matches the GunnAire Apple team",
        "Mac Catalyst hardened-runtime or team signature is missing",
    )
    privacy = run(["plutil", "-lint", str(privacy_path)], check=False)
    results.require(
        privacy.returncode == 0,
        "Mac Catalyst privacy manifest is valid",
        "Mac Catalyst privacy manifest is invalid",
    )

    try:
        app_info = load_plist(info_path)
        archived_privacy = load_plist(privacy_path)
        entitlements = extract_codesign_entitlements(app_path)
        profile = extract_profile(profile_path)
        profile_entitlements = profile.get("Entitlements", {})
        expected_application_id = f"{EXPECTED_TEAM_ID}.{EXPECTED_BUNDLE_ID}"

        results.require(
            app_info.get("CFBundleIdentifier") == EXPECTED_BUNDLE_ID
            and app_info.get("CFBundleShortVersionString") == marketing_version
            and app_info.get("CFBundleVersion") == build_version,
            f"Mac Catalyst artifact exactly matches source {marketing_version} ({build_version}) and bundle ID",
            "Mac Catalyst version/build/bundle does not match the source",
        )
        results.require(
            app_info.get("ITSAppUsesNonExemptEncryption") is False,
            "Mac Catalyst artifact declares no non-exempt encryption for export-compliance routing",
            "Mac Catalyst export-compliance declaration is missing or unexpected",
        )
        expected_settings = {
            "GUNNAIRE_BACKEND_BASE_URL": EXPECTED_BACKEND_URL,
            "GUNNAIRE_BACKEND_AUTH_MODE": "google-id-token",
            "GUNNAIRE_BACKEND_API_TOKEN": "",
            "QB_ENVIRONMENT": "production",
            "QB_REDIRECT_URI": EXPECTED_QBO_REDIRECT,
            "QB_CALLBACK_SCHEME": EXPECTED_QBO_CALLBACK_SCHEME,
            "QB_ENABLE_PAYMENTS_SCOPE": "true",
        }
        mismatches = {
            key: app_info.get(key)
            for key, expected in expected_settings.items()
            if app_info.get(key) != expected
        }
        results.require(
            not mismatches,
            "Mac Catalyst artifact uses HTTPS business identity, an empty shared token, and production QBO settings",
            f"Mac Catalyst production settings are incorrect: {mismatches}",
        )
        results.require(
            bool(str(app_info.get("QB_CLIENT_ID", "")).strip())
            and bool(str(app_info.get("GOOGLE_CLIENT_ID", "")).strip())
            and app_info.get("GOOGLE_CALLBACK_SCHEME")
            == app_info.get("GOOGLE_REVERSED_CLIENT_ID"),
            "Mac Catalyst artifact contains matching non-secret QBO and Google OAuth identifiers",
            "Mac Catalyst QBO/Google OAuth identifiers are incomplete or inconsistent",
        )
        collected_types = {
            row.get("NSPrivacyCollectedDataType")
            for row in archived_privacy.get("NSPrivacyCollectedDataTypes", [])
            if isinstance(row, dict)
        }
        results.require(
            {
                "NSPrivacyCollectedDataTypeDeviceID",
                "NSPrivacyCollectedDataTypePaymentInfo",
                "NSPrivacyCollectedDataTypeOtherFinancialInfo",
            }.issubset(collected_types),
            "Mac Catalyst privacy manifest covers device, payment, and financial data",
            "Mac Catalyst privacy manifest omits release-critical data categories",
        )
        entitlement_checks = (
            entitlements.get("application-identifier") == expected_application_id,
            entitlements.get("com.apple.developer.applesignin") == ["Default"],
            EXPECTED_ICLOUD_CONTAINER
            in entitlements.get("com.apple.developer.icloud-container-identifiers", []),
            entitlements.get("com.apple.developer.icloud-services") == ["CloudKit"],
            EXPECTED_ASSOCIATED_DOMAIN
            in entitlements.get("com.apple.developer.associated-domains", []),
            entitlements.get("aps-environment") in {"development", "production"},
        )
        results.require(
            all(entitlement_checks),
            "Mac Catalyst artifact includes Apple login, Push, CloudKit, and Associated Domains",
            "Mac Catalyst Apple capability entitlements are incomplete",
        )
        results.require(
            profile_entitlements.get("application-identifier") == expected_application_id
            and is_future_datetime(profile.get("ExpirationDate"))
            and EXPECTED_TEAM_ID in profile.get("TeamIdentifier", []),
            f"Mac Catalyst profile {profile.get('UUID', 'unknown')} is current and matches the GunnAire app/team",
            "Mac Catalyst profile is expired or does not match the GunnAire app/team",
        )

        distribution_signed = (
            "Authority=Apple Distribution" in signature_text
            and entitlements.get("get-task-allow") is False
            and entitlements.get("aps-environment") == "production"
        )
        if distribution_signed:
            results.pass_("Mac Catalyst artifact is distribution signed")
        elif require_app_store_signing:
            results.fail("Mac Catalyst artifact is not distribution signed")
        else:
            results.warn(
                "Mac Catalyst artifact is development signed; a separate Mac distribution profile/private key remains required"
            )
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        results.fail(f"Mac Catalyst metadata/entitlement inspection failed: {error}")

    architectures = run(["lipo", "-archs", str(binary_path)], check=False)
    architecture_set = set(architectures.stdout.decode("utf-8").split())
    results.require(
        architectures.returncode == 0 and architecture_set == {"arm64", "x86_64"},
        "Mac Catalyst binary is universal arm64/x86_64",
        f"Mac Catalyst binary architectures are unexpected: {sorted(architecture_set)}",
    )
    try:
        app_uuids = binary_uuids(binary_path)
        dsym_uuids = binary_uuids(dsym_binary)
        results.require(
            len(app_uuids) == 2 and app_uuids == dsym_uuids,
            f"Mac Catalyst app and dSYM UUIDs match both slices: {', '.join(sorted(app_uuids))}",
            f"Mac Catalyst app/dSYM UUID mismatch: app={sorted(app_uuids)} dSYM={sorted(dsym_uuids)}",
        )
        results.pass_(f"Mac Catalyst binary SHA-256 is {sha256(binary_path)}")
    except (OSError, subprocess.CalledProcessError) as error:
        results.fail(f"Mac Catalyst binary/dSYM inspection failed: {error}")

    strings_process = run(["strings", str(binary_path)], check=False)
    strings_text = strings_process.stdout.decode("utf-8", errors="replace")
    forbidden = [
        marker
        for marker in ("-uiTest", "bootstrap", "localhost", "127.0.0.1")
        if marker in strings_text
    ]
    results.require(
        strings_process.returncode == 0 and not forbidden,
        "Mac Catalyst binary contains no UI-test, bootstrap, or local-host markers",
        f"Mac Catalyst binary contains forbidden markers: {forbidden}",
    )


def check_mac_result(path: Path, results: Results) -> None:
    process = run(
        ["xcrun", "xcresulttool", "get", "build-results", "--path", str(path), "--compact"],
        check=False,
    )
    if process.returncode != 0:
        results.fail("Mac Catalyst build result could not be inspected")
        return
    try:
        payload = json.loads(process.stdout)
    except json.JSONDecodeError as error:
        results.fail(f"Mac Catalyst build result is not valid JSON: {error}")
        return
    results.require(
        payload.get("status") == "succeeded"
        and payload.get("errorCount") == 0
        and payload.get("analyzerWarningCount") == 0,
        "Mac Catalyst Xcode result succeeded with zero errors and analyzer warnings",
        "Mac Catalyst Xcode result contains a failure, error, or analyzer warning",
    )
    warnings = payload.get("warnings", [])
    if not warnings:
        results.pass_("Mac Catalyst Xcode result contains zero warnings")
        return
    messages = [str(warning.get("message", "")) for warning in warnings]
    known_host_warning = all(
        "Metal.xctoolchain" in message and "Search path" in message
        for message in messages
    )
    if known_host_warning:
        results.warn(
            "Mac Catalyst Xcode result contains only the host's missing optional Metal toolchain search-path warning"
        )
    else:
        results.fail(f"Mac Catalyst Xcode result contains unexpected warnings: {messages}")


def parse_cloudkit_schema(path: Path) -> dict[str, dict[str, tuple[str, ...]]]:
    text = path.read_text(encoding="utf-8")
    records: dict[str, dict[str, tuple[str, ...]]] = {}
    for match in re.finditer(r"RECORD TYPE\s+(\w+)\s*\((.*?)\n\s*\);", text, re.DOTALL):
        fields: dict[str, tuple[str, ...]] = {}
        for raw_line in match.group(2).splitlines():
            line = raw_line.strip().rstrip(",")
            if not line.startswith("CD_"):
                continue
            parts = tuple(line.split())
            fields[parts[0]] = parts[1:]
        records[match.group(1)] = fields
    if not records:
        raise ValueError(f"No CloudKit record types found in {path}")
    return records


def check_cloudkit(development: Path, production: Path, results: Results) -> None:
    try:
        dev = parse_cloudkit_schema(development)
        prod = parse_cloudkit_schema(production)
        results.require(
            set(dev) == set(prod) and len(dev) == 24,
            "CloudKit exports contain the same 24 record types",
            f"CloudKit record types differ: development={len(dev)} production={len(prod)}",
        )
        actual_additions: dict[str, dict[str, tuple[str, ...]]] = {}
        changed_or_removed: list[str] = []
        for record_name in sorted(set(dev) | set(prod)):
            dev_fields = dev.get(record_name, {})
            prod_fields = prod.get(record_name, {})
            for field_name, production_definition in prod_fields.items():
                if dev_fields.get(field_name) != production_definition:
                    changed_or_removed.append(f"{record_name}.{field_name}")
            added = {
                name: definition
                for name, definition in dev_fields.items()
                if name not in prod_fields
            }
            if added:
                actual_additions[record_name] = added
        results.require(
            not changed_or_removed,
            "Development changes remove or alter no Production CloudKit fields",
            f"Development removes or alters Production fields: {changed_or_removed}",
        )
        if not actual_additions:
            missing_or_changed_v15_fields: list[str] = []
            for record_name, expected_fields in EXPECTED_CLOUDKIT_V15_ADDITIONS.items():
                development_fields = dev.get(record_name, {})
                production_fields = prod.get(record_name, {})
                for field_name, expected_definition in expected_fields.items():
                    if (
                        development_fields.get(field_name) != expected_definition
                        or production_fields.get(field_name) != expected_definition
                    ):
                        missing_or_changed_v15_fields.append(f"{record_name}.{field_name}")
            results.require(
                not missing_or_changed_v15_fields,
                "CloudKit Production exactly matches Development with every approved v15 field",
                "CloudKit exports match, but approved v15 fields are missing or changed: "
                f"{missing_or_changed_v15_fields}",
            )
        elif actual_additions == EXPECTED_CLOUDKIT_V13_ADDITIONS:
            results.pass_(
                "CloudKit Development v13 delta is exactly six additive tax fields on Estimate and Invoice"
            )
            results.warn(
                "CloudKit source v15 fields are not staged in Development; run the signed v15 bootstrap before promotion review"
            )
        elif actual_additions == EXPECTED_CLOUDKIT_V14_ADDITIONS:
            results.pass_(
                "CloudKit Development v14 cumulative delta is exactly six tax fields plus Invoice.dueDate"
            )
            results.warn(
                "CloudKit source v15 Item continuity and package fields are not staged in Development; run the signed v15 bootstrap before promotion review"
            )
        elif actual_additions == EXPECTED_CLOUDKIT_V15_ADDITIONS:
            results.pass_(
                "CloudKit Development v15 cumulative delta is exactly the approved tax, due-date, inventory continuity, Item continuity, and service-package fields"
            )
        else:
            results.fail(f"Unexpected CloudKit v13/v14/v15 delta: {actual_additions}")
        results.pass_(f"Development export SHA-256 is {sha256(development)}")
        results.pass_(f"Production export SHA-256 is {sha256(production)}")
    except (OSError, ValueError) as error:
        results.fail(f"CloudKit export inspection failed: {error}")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


def http_status(request: urllib.request.Request) -> tuple[int, dict[str, str], bytes]:
    opener = urllib.request.build_opener(NoRedirect())
    try:
        with opener.open(request, timeout=20) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read()


def check_online(expected_backend_version: str, results: Results) -> None:
    try:
        status, _, body = http_status(
            urllib.request.Request(f"{EXPECTED_BACKEND_URL}/health")
        )
        payload = json.loads(body)
        actual_version = payload.get("serviceVersion")
        results.require(
            status == 200 and actual_version == expected_backend_version,
            f"Production backend is healthy on source version {expected_backend_version}",
            f"Production backend gate is not met: HTTP {status}, serviceVersion={actual_version!r}, expected={expected_backend_version!r}",
        )

        apple_request = urllib.request.Request(
            f"{EXPECTED_BACKEND_URL}/api/auth/apple/notifications",
            data=b"{}",
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        apple_status, _, _ = http_status(apple_request)
        results.require(
            apple_status == 400,
            "Production Apple notification route rejects a malformed envelope with HTTP 400",
            f"Production Apple notification route returned HTTP {apple_status}; HTTP 401 identifies the old backend",
        )

        callback_status, callback_headers, _ = http_status(
            urllib.request.Request(EXPECTED_QBO_REDIRECT)
        )
        location = callback_headers.get("Location", "")
        results.require(
            callback_status in {301, 302, 303, 307, 308}
            and location.startswith(f"{EXPECTED_QBO_CALLBACK_SCHEME}://"),
            "Production QBO HTTPS callback reaches the GunnAire app scheme",
            f"QBO callback gate failed: HTTP {callback_status}, Location={location!r}",
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        results.fail(f"Online production preflight failed: {error}")


def main() -> int:
    args = parse_args()
    root = args.project_root.resolve()
    results = Results()
    marketing_version, build_version, backend_version = check_source(root, results)

    archive = args.archive
    if archive is None and marketing_version and build_version:
        archive = find_archive(marketing_version, build_version)
    if archive is None:
        results.fail("No matching Current Source archive was supplied or discovered")
    else:
        check_archive(
            archive.expanduser().resolve(),
            marketing_version,
            build_version,
            args.require_app_store_signing,
            results,
        )

    app_store_profile = args.app_store_profile or find_app_store_profile()
    if app_store_profile is None:
        results.warn("No matching installed App Store profile was supplied or discovered")
    else:
        check_app_store_profile(app_store_profile.expanduser().resolve(), results)

    mac_app = args.mac_app or (find_mac_app(build_version) if build_version else None)
    if mac_app is None:
        results.warn("No exact current-source Mac Catalyst Release app was supplied or discovered")
    else:
        check_mac_app(
            mac_app.expanduser().resolve(),
            marketing_version,
            build_version,
            args.require_app_store_signing,
            results,
        )

    mac_result = args.mac_result or (find_mac_result(build_version) if build_version else None)
    if mac_result is None:
        results.warn("No current-source Mac Catalyst build result was supplied or discovered")
    else:
        check_mac_result(mac_result.expanduser().resolve(), results)

    cloudkit_arguments = (
        args.cloudkit_development_export,
        args.cloudkit_production_export,
    )
    if any(cloudkit_arguments) and not all(cloudkit_arguments):
        results.fail("Both CloudKit export paths are required when either is supplied")
    elif all(cloudkit_arguments):
        check_cloudkit(
            args.cloudkit_development_export.expanduser().resolve(),
            args.cloudkit_production_export.expanduser().resolve(),
            results,
        )
    else:
        results.warn("CloudKit exports were not supplied; the exact v13/v14/v15 Production delta was not rechecked")

    if args.online:
        check_online(backend_version, results)
    else:
        results.warn("Online production probes were not requested")

    print()
    print(
        f"SUMMARY {results.passed} passed, {results.warnings} warnings, "
        f"{len(results.failures)} failures"
    )
    if results.failures:
        print("RELEASE PREFLIGHT FAILED")
        return 1
    print("RELEASE PREFLIGHT PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
