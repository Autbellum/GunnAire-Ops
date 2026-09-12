from __future__ import annotations

import copy
import unittest
from datetime import datetime, timezone
from pathlib import Path

try:
    from Tools import physical_device_acceptance as acceptance
except ModuleNotFoundError:  # Direct execution from the Tools directory.
    import physical_device_acceptance as acceptance


class PhysicalDeviceAcceptanceTests(unittest.TestCase):
    def device(
        self,
        device_type: str,
        *,
        available: bool = True,
        marketing_version: str | None = "1.0",
        build_version: str | None = "2026083101",
        app_inspection_succeeded: bool = True,
    ) -> acceptance.DeviceSummary:
        return acceptance.DeviceSummary(
            device_ref=f"{device_type.lower()}-ref",
            device_type=device_type,
            marketing_name=f"Test {device_type} Pro",
            os_version="26.6",
            pairing_state="paired",
            tunnel_state="connected" if available else "unavailable",
            developer_mode="enabled",
            ddi_services_available=available,
            installed_marketing_version=marketing_version,
            installed_build_version=build_version,
            app_inspection_succeeded=app_inspection_succeeded,
        )

    def complete_record(self) -> dict:
        record = acceptance.acceptance_record_template("1.0", "2026083101")
        record["run"].update(
            {
                "startedAtUTC": "2026-08-31T12:00:00Z",
                "completedAtUTC": "2026-08-31T13:00:00Z",
                "operator": "Release operator",
            }
        )
        for device in record["devices"].values():
            device.update({"model": "Acceptance hardware", "osVersion": "26.6"})
        for scenario in record["scenarios"]:
            scenario["status"] = "passed"
            scenario["evidence"] = [f"evidence/{scenario['id']}.json"]
        return record

    def test_device_summary_omits_hardware_identifiers(self) -> None:
        raw = {
            "identifier": "private-core-device-id",
            "deviceProperties": {
                "name": "PERSONAL-NAME-SHOULD-NOT-LEAK",
                "osVersionNumber": "26.6",
                "developerModeStatus": "enabled",
                "ddiServicesAvailable": True,
            },
            "hardwareProperties": {
                "deviceType": "iPhone",
                "marketingName": "iPhone Pro",
                "serialNumber": "SERIAL-SHOULD-NOT-LEAK",
                "udid": "UDID-SHOULD-NOT-LEAK",
            },
            "connectionProperties": {
                "pairingState": "paired",
                "tunnelState": "connected",
            },
        }

        summary = acceptance.summarize_device(raw)

        self.assertTrue(summary.is_available)
        self.assertNotIn("SERIAL", repr(summary))
        self.assertNotIn("UDID", repr(summary))
        self.assertNotIn("PERSONAL-NAME", repr(summary))
        self.assertNotEqual(summary.device_ref, raw["identifier"])

    def test_live_details_replace_a_stale_disconnected_device_listing(self) -> None:
        identifier = "private-core-device-id"
        stale = {
            "identifier": identifier,
            "deviceProperties": {
                "osVersionNumber": "26.6.1",
                "developerModeStatus": "enabled",
                "ddiServicesAvailable": False,
            },
            "hardwareProperties": {
                "deviceType": "iPad",
                "marketingName": "iPad Pro 13-inch (M5)",
            },
            "connectionProperties": {
                "pairingState": "paired",
                "tunnelState": "disconnected",
            },
        }
        current = copy.deepcopy(stale)
        current["deviceProperties"]["ddiServicesAvailable"] = True
        current["connectionProperties"]["tunnelState"] = "connected"

        rows = acceptance.refresh_device_rows(
            [stale],
            lambda requested: current if requested == identifier else None,
        )

        self.assertEqual(rows, [current])
        self.assertTrue(acceptance.summarize_device(rows[0]).is_available)

    def test_device_details_parser_rejects_a_different_device(self) -> None:
        payload = {"result": {"identifier": "unexpected-device"}}

        with self.assertRaisesRegex(ValueError, "different device"):
            acceptance.parse_device_details_payload(
                payload,
                expected_identifier="expected-device",
            )

    def test_installed_app_parser_returns_only_the_expected_bundle_versions(self) -> None:
        payload = {
            "result": {
                "deviceIdentifier": "PRIVATE-DEVICE-ID",
                "apps": [
                    {
                        "name": "Unrelated App",
                        "bundleIdentifier": "com.example.unrelated",
                        "version": "99",
                        "bundleVersion": "999",
                    },
                    {
                        "name": "GunnAire Ops",
                        "bundleIdentifier": acceptance.EXPECTED_BUNDLE_ID,
                        "version": "1.0",
                        "bundleVersion": "2026090204",
                    },
                ],
            }
        }

        self.assertEqual(
            acceptance.parse_installed_app_payload(payload),
            ("1.0", "2026090204"),
        )
        self.assertNotIn("PRIVATE-DEVICE-ID", repr(acceptance.parse_installed_app_payload(payload)))

    def test_readiness_requires_the_exact_build_on_each_connected_device_family(self) -> None:
        report = acceptance.build_readiness_report(
            marketing_version="1.0",
            build_version="2026083101",
            archive=Path("/tmp/missing-archive"),
            mac_app=Path("/tmp/missing-app"),
            identities={"development": 1, "ios_distribution": 0, "mac_distribution": 0},
            devices=[
                self.device("iPad"),
                self.device("iPhone", build_version="2026083001"),
            ],
        )

        checks = {item["id"]: item for item in report["checks"]}
        self.assertEqual(checks["physical-ipad"]["status"], "pass")
        self.assertEqual(checks["physical-iphone"]["status"], "blocked")
        self.assertIn("exact build 2026083101", checks["physical-ipad"]["detail"])
        self.assertIn("not confirmed installed", checks["physical-iphone"]["detail"])
        self.assertTrue(report["devices"][0]["is_current_build"])
        self.assertFalse(report["devices"][1]["is_current_build"])

    def test_readiness_requires_device_families_and_distribution(self) -> None:
        report = acceptance.build_readiness_report(
            marketing_version="1.0",
            build_version="2026083101",
            archive=Path("/tmp/missing-archive"),
            mac_app=Path("/tmp/missing-app"),
            identities={"development": 1, "ios_distribution": 0, "mac_distribution": 0},
            devices=[self.device("iPad", available=False)],
        )

        self.assertFalse(report["readiness"]["signedDeviceAcceptance"])
        self.assertFalse(report["readiness"]["appStoreExport"])
        self.assertFalse(report["readiness"]["macDistribution"])
        self.assertFalse(any("serial" in str(value).lower() for value in report["devices"]))

    def test_complete_current_build_record_passes(self) -> None:
        errors = acceptance.validate_acceptance_record(
            self.complete_record(),
            marketing_version="1.0",
            build_version="2026083101",
            now=datetime(2026, 8, 31, 14, 0, tzinfo=timezone.utc),
        )

        self.assertEqual(errors, [])

    def test_missing_evidence_and_stale_build_fail(self) -> None:
        record = self.complete_record()
        record["application"]["buildVersion"] = "2026083021"
        record["scenarios"][0]["evidence"] = []

        errors = acceptance.validate_acceptance_record(
            record,
            marketing_version="1.0",
            build_version="2026083101",
            now=datetime(2026, 8, 31, 14, 0, tzinfo=timezone.utc),
        )

        self.assertTrue(any("buildVersion" in error for error in errors))
        self.assertTrue(any("evidence reference" in error for error in errors))

    def test_production_provider_evidence_requires_explicit_references(self) -> None:
        record = self.complete_record()
        record["run"]["qboEnvironment"] = "production"
        record["run"]["cloudKitEnvironment"] = "Production"

        errors = acceptance.validate_acceptance_record(
            record,
            marketing_version="1.0",
            build_version="2026083101",
            now=datetime(2026, 8, 31, 14, 0, tzinfo=timezone.utc),
        )

        self.assertTrue(any("productionMutationAuthorizationReference" in error for error in errors))
        self.assertTrue(any("productionPromotionApprovalReference" in error for error in errors))

    def test_duplicate_and_incomplete_scenarios_fail(self) -> None:
        record = self.complete_record()
        record["scenarios"].append(copy.deepcopy(record["scenarios"][0]))
        record["scenarios"][1]["status"] = "blocked"

        errors = acceptance.validate_acceptance_record(
            record,
            marketing_version="1.0",
            build_version="2026083101",
            now=datetime(2026, 8, 31, 14, 0, tzinfo=timezone.utc),
        )

        self.assertTrue(any("duplicated" in error for error in errors))
        self.assertTrue(any("must be passed" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
