import contextlib
import copy
import io
import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

try:
    from Tools import release_preflight
except ModuleNotFoundError:  # Direct execution from the Tools directory.
    import release_preflight


class CloudKitV22PreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.production = {
            record_name: {}
            for record_name in release_preflight.EXPECTED_CLOUDKIT_BASELINE_RECORD_TYPES
        }
        self.development = copy.deepcopy(self.production)
        for record_name, fields in release_preflight.EXPECTED_CLOUDKIT_V22_ADDITIONS.items():
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

    def test_exact_cumulative_v22_schema_is_accepted(self) -> None:
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
        self.assertTrue(any("v22" in failure.lower() for failure in results.failures))

    def test_partial_recurring_work_shift_fields_are_rejected(self) -> None:
        partial_development = copy.deepcopy(self.development)
        partial_development["CD_TechnicianWorkShift"].pop("CD_retirementOperationID")

        results = self.check(partial_development, self.production)

        self.assertTrue(results.failures)
        self.assertTrue(any("v22" in failure.lower() for failure in results.failures))

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


if __name__ == "__main__":
    unittest.main()
