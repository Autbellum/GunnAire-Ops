import copy
import unittest
from datetime import datetime, timezone
from pathlib import Path

try:
    from Tools import physical_device_acceptance as acceptance
except ModuleNotFoundError:  # Direct execution from the Tools directory.
    import physical_device_acceptance as acceptance


class PhysicalDeviceAcceptanceTests(unittest.TestCase):
    def device(self, device_type: str, *, available: bool = True) -> acceptance.DeviceSummary:
        return acceptance.DeviceSummary(
            device_ref=f"{device_type.lower()}-ref",
            device_type=device_type,
            marketing_name=f"Test {device_type} Pro",
            os_version="26.6",
            pairing_state="paired",
            tunnel_state="connected" if available else "unavailable",
            developer_mode="enabled",
            ddi_services_available=available,
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
