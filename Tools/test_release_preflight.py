import contextlib
import copy
import io
import json
import plistlib
import struct
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest.mock import patch

try:
    from Tools import release_preflight
except ModuleNotFoundError:  # Direct execution from the Tools directory.
    import release_preflight


class CloudKitV23PreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.production = {
            record_name: {}
            for record_name in release_preflight.EXPECTED_CLOUDKIT_BASELINE_RECORD_TYPES
        }
        self.development = copy.deepcopy(self.production)
        for record_name, fields in release_preflight.EXPECTED_CLOUDKIT_V23_ADDITIONS.items():
            self.development.setdefault(record_name, {}).update(fields)
        baseline_metadata = {
            "system_fields": release_preflight.EXPECTED_CLOUDKIT_SYSTEM_FIELDS,
            "grants": release_preflight.EXPECTED_CLOUDKIT_RECORD_GRANTS,
        }
        self.production_metadata = {
            record_name: copy.deepcopy(baseline_metadata)
            for record_name in self.production
        }
        self.development_metadata = {
            record_name: copy.deepcopy(baseline_metadata)
            for record_name in self.development
        }

    def check(
        self,
        development: dict,
        production: dict,
        development_metadata=None,
        production_metadata=None,
    ) -> release_preflight.Results:
        def schema(path: Path) -> dict:
            return development if path.name == "development.ckdb" else production

        def metadata(path: Path) -> dict:
            if path.name == "development.ckdb":
                return development_metadata or self.development_metadata
            return production_metadata or self.production_metadata

        results = release_preflight.Results()
        with patch.object(release_preflight, "parse_cloudkit_schema", side_effect=schema), \
             patch.object(release_preflight, "parse_cloudkit_record_metadata", side_effect=metadata), \
             patch.object(release_preflight, "sha256", return_value="synthetic"), \
             contextlib.redirect_stdout(io.StringIO()):
            release_preflight.check_cloudkit(
                Path("development.ckdb"),
                Path("production.ckdb"),
                results,
            )
        return results

    def test_exact_cumulative_v23_schema_is_accepted(self) -> None:
        results = self.check(self.development, self.production)

        self.assertEqual(results.failures, [])
        self.assertEqual(results.warnings, 0)

    def test_partial_time_off_record_pair_is_rejected(self) -> None:
        partial_development = copy.deepcopy(self.development)
        partial_development.pop("CD_TechnicianAvailabilityEvent")

        results = self.check(partial_development, self.production)

        self.assertTrue(results.failures)
        self.assertTrue(any("record types" in failure.lower() for failure in results.failures))

    def test_partial_availability_block_audit_fields_are_rejected(self) -> None:
        partial_development = copy.deepcopy(self.development)
        partial_development["CD_TechnicianAvailabilityBlock"].pop("CD_cancellationReason")

        results = self.check(partial_development, self.production)

        self.assertTrue(results.failures)
        self.assertTrue(any("v23" in failure.lower() for failure in results.failures))

    def test_partial_recurring_work_shift_fields_are_rejected(self) -> None:
        partial_development = copy.deepcopy(self.development)
        partial_development["CD_TechnicianWorkShift"].pop("CD_retirementOperationID")

        results = self.check(partial_development, self.production)

        self.assertTrue(results.failures)
        self.assertTrue(any("v23" in failure.lower() for failure in results.failures))

    def test_partial_v23_operational_field_closure_is_rejected(self) -> None:
        partial_development = copy.deepcopy(self.development)
        partial_development["CD_Payment"].pop("CD_quickBooksClientTransID")

        results = self.check(partial_development, self.production)

        self.assertTrue(results.failures)
        self.assertTrue(any("v23" in failure.lower() for failure in results.failures))

    def test_existing_record_security_grant_change_is_rejected(self) -> None:
        altered_metadata = copy.deepcopy(self.development_metadata)
        altered_metadata["CD_AppUser"]["grants"] = ('GRANT READ TO "_world"',)

        results = self.check(
            self.development,
            self.production,
            development_metadata=altered_metadata,
        )

        self.assertTrue(results.failures)
        self.assertTrue(any("security grants" in failure.lower() for failure in results.failures))


class AppStoreMetadataPreflightTests(unittest.TestCase):
    def contract(self) -> dict:
        return {
            "schemaVersion": 1,
            "app": {
                "bundleID": release_preflight.EXPECTED_BUNDLE_ID,
                "primaryLocale": release_preflight.EXPECTED_APP_STORE_LOCALE,
                "privacyPolicyURL": "https://gunnaire.com/privacy-policy.html",
                "supportURL": "https://gunnaire.com",
                "marketingURL": "https://gunnaire.com",
            },
            "appReview": {
                "requiresSignIn": True,
                "credentialStorage": "App Store Connect only",
            },
            "privacy": {
                "tracking": False,
                "dataTypes": [
                    {
                        "manifestDataType": "NSPrivacyCollectedDataTypeName",
                        "category": "Contact Info",
                        "displayName": "Name",
                        "linkedToUser": True,
                        "tracking": False,
                        "purposes": [release_preflight.EXPECTED_APP_STORE_PRIVACY_PURPOSE],
                        "usage": "Business identity",
                    }
                ],
            },
        }

    def privacy_manifest(self) -> dict:
        return {
            "NSPrivacyTracking": False,
            "NSPrivacyCollectedDataTypes": [
                {
                    "NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeName",
                    "NSPrivacyCollectedDataTypeLinked": True,
                    "NSPrivacyCollectedDataTypeTracking": False,
                    "NSPrivacyCollectedDataTypePurposes": [
                        release_preflight.EXPECTED_APP_STORE_PRIVACY_PURPOSE
                    ],
                }
            ],
        }

    def check(self, contract: dict, manifest=None) -> release_preflight.Results:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata_path = root / release_preflight.EXPECTED_APP_STORE_METADATA_PATH
            metadata_path.parent.mkdir(parents=True)
            metadata_path.write_text(json.dumps(contract), encoding="utf-8")
            privacy_path = root / "GunnAire Ops" / "PrivacyInfo.xcprivacy"
            privacy_path.parent.mkdir(parents=True)
            with privacy_path.open("wb") as stream:
                plistlib.dump(manifest or self.privacy_manifest(), stream)
            results = release_preflight.Results()
            with contextlib.redirect_stdout(io.StringIO()):
                release_preflight.check_app_store_metadata(root, results)
            return results

    def test_exact_app_store_privacy_contract_is_accepted(self) -> None:
        results = self.check(self.contract())

        self.assertEqual(results.failures, [])
        self.assertEqual(results.warnings, 0)

    def test_missing_manifest_data_type_is_rejected(self) -> None:
        contract = self.contract()
        contract["privacy"]["dataTypes"] = []

        results = self.check(contract)

        self.assertTrue(any("differ" in failure.lower() for failure in results.failures))

    def test_linkage_or_purpose_drift_is_rejected(self) -> None:
        contract = self.contract()
        answer = contract["privacy"]["dataTypes"][0]
        answer["linkedToUser"] = False
        answer["purposes"] = []

        results = self.check(contract)

        self.assertTrue(any("do not match" in failure.lower() for failure in results.failures))

    def test_review_credentials_cannot_be_committed(self) -> None:
        contract = self.contract()
        contract["appReview"]["reviewPassword"] = "should-not-be-here"

        results = self.check(contract)

        self.assertTrue(any("credentials" in failure.lower() for failure in results.failures))


class AppStoreScreenshotPreflightTests(unittest.TestCase):
    @staticmethod
    def png_chunk(chunk_type: bytes, data: bytes) -> bytes:
        checksum = zlib.crc32(chunk_type)
        checksum = zlib.crc32(data, checksum) & 0xFFFFFFFF
        return (
            struct.pack(">I", len(data))
            + chunk_type
            + data
            + struct.pack(">I", checksum)
        )

    def write_png(
        self,
        path: Path,
        width: int,
        height: int,
        *,
        color_type: int = 2,
    ) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
        path.write_bytes(
            b"\x89PNG\r\n\x1a\n"
            + self.png_chunk(b"IHDR", ihdr)
            + self.png_chunk(b"IDAT", zlib.compress(b"synthetic fixture"))
            + self.png_chunk(b"IEND", b"")
        )

    def check(self, mutate=None) -> release_preflight.Results:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = {
                "schemaVersion": 1,
                "sourceVersion": "1.0",
                "sourceBuild": "2026090501",
                "reviewedAt": "2026-09-05",
                "captureEvidence": {
                    set_name: f"{set_name} 2026090501.xcresult"
                    for set_name in release_preflight.EXPECTED_APP_STORE_SCREENSHOT_SETS
                },
                "sets": {},
            }
            for set_name, expected in (
                release_preflight.EXPECTED_APP_STORE_SCREENSHOT_SETS.items()
            ):
                rows = []
                for filename in expected["filenames"]:
                    path = root / "AppStoreAssets" / "Screenshots" / set_name / filename
                    self.write_png(path, expected["width"], expected["height"])
                    rows.append(
                        {"name": filename, "sha256": release_preflight.sha256(path)}
                    )
                manifest["sets"][set_name] = {
                    "width": expected["width"],
                    "height": expected["height"],
                    "files": rows,
                }

            if mutate is not None:
                mutate(root, manifest)
            manifest_path = root / release_preflight.EXPECTED_APP_STORE_SCREENSHOT_MANIFEST_PATH
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            results = release_preflight.Results()
            with contextlib.redirect_stdout(io.StringIO()):
                release_preflight.check_app_store_screenshots(
                    root,
                    "1.0",
                    "2026090501",
                    results,
                )
            return results

    def test_exact_current_screenshot_set_is_accepted(self) -> None:
        results = self.check()

        self.assertEqual(results.failures, [])
        self.assertEqual(results.warnings, 0)

    def test_stale_source_build_is_rejected(self) -> None:
        results = self.check(
            lambda _root, manifest: manifest.update(sourceBuild="2026090401")
        )

        self.assertTrue(any("stale" in failure.lower() for failure in results.failures))

    def test_hash_drift_is_rejected(self) -> None:
        def mutate(_root: Path, manifest: dict) -> None:
            manifest["sets"]["iPad-13-inch"]["files"][0]["sha256"] = "0" * 64

        results = self.check(mutate)

        self.assertTrue(any("audited hash" in failure.lower() for failure in results.failures))

    def test_alpha_image_is_rejected_even_when_hash_is_current(self) -> None:
        def mutate(root: Path, manifest: dict) -> None:
            set_name = "iPhone-6.9-inch"
            row = manifest["sets"][set_name]["files"][0]
            path = root / "AppStoreAssets" / "Screenshots" / set_name / row["name"]
            expected = release_preflight.EXPECTED_APP_STORE_SCREENSHOT_SETS[set_name]
            self.write_png(path, expected["width"], expected["height"], color_type=6)
            row["sha256"] = release_preflight.sha256(path)

        results = self.check(mutate)

        self.assertTrue(any("transparency" in failure.lower() for failure in results.failures))

    def test_wrong_dimensions_are_rejected_even_when_hash_is_current(self) -> None:
        def mutate(root: Path, manifest: dict) -> None:
            set_name = "iPad-13-inch"
            row = manifest["sets"][set_name]["files"][1]
            path = root / "AppStoreAssets" / "Screenshots" / set_name / row["name"]
            expected = release_preflight.EXPECTED_APP_STORE_SCREENSHOT_SETS[set_name]
            self.write_png(path, expected["width"] - 1, expected["height"])
            row["sha256"] = release_preflight.sha256(path)

        results = self.check(mutate)

        self.assertTrue(any("expected" in failure.lower() for failure in results.failures))

    def test_unexpected_png_is_rejected(self) -> None:
        def mutate(root: Path, _manifest: dict) -> None:
            path = (
                root
                / "AppStoreAssets"
                / "Screenshots"
                / "iPad-13-inch"
                / "07-unreviewed.png"
            )
            self.write_png(path, 2064, 2752)

        results = self.check(mutate)

        self.assertTrue(any("unexpected" in failure.lower() for failure in results.failures))


if __name__ == "__main__":
    unittest.main()
