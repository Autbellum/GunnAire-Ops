import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

try:
    from Tools import cloudkit_conflict_acceptance as acceptance
except ModuleNotFoundError:
    import cloudkit_conflict_acceptance as acceptance


class CloudKitConflictAcceptanceTests(unittest.TestCase):
    build = "2026090111"

    def report(self, phase: acceptance.Phase) -> dict:
        return {
            "schemaVersion": 2,
            "generatedAtUTC": "2026-09-02T13:00:00Z",
            "applicationBuild": self.build,
            "mode": phase.mode,
            "attempt": 1,
            "state": phase.state,
            "matchCount": phase.match_count,
            "actionPerformed": phase.mode not in {
                "observeConflictSeed",
                "observeConflictConverged",
                "observeConflictResolved",
                "observeConflictDeleted",
            },
            "expectationMet": True,
            "errorCode": None,
        }

    def test_every_phase_accepts_only_its_exact_report(self) -> None:
        now = datetime(2026, 9, 2, 13, 1, tzinfo=timezone.utc)
        for phase in acceptance.PHASES:
            with self.subTest(phase=phase.identifier):
                self.assertEqual(
                    acceptance.validate_probe_report(
                        self.report(phase),
                        phase=phase,
                        expected_build=self.build,
                        now=now,
                    ),
                    [],
                )

    def test_wrong_build_state_count_and_error_fail_closed(self) -> None:
        phase = acceptance.PHASE_BY_ID["mac-seed"]
        report = self.report(phase)
        report.update(
            {
                "applicationBuild": "2026090110",
                "state": "conflictA",
                "matchCount": 2,
                "expectationMet": False,
                "errorCode": "private detail must not be retained",
            }
        )

        errors = acceptance.validate_probe_report(
            report,
            phase=phase,
            expected_build=self.build,
            now=datetime(2026, 9, 2, 13, 1, tzinfo=timezone.utc),
        )

        self.assertTrue(any("applicationBuild" in error for error in errors))
        self.assertTrue(any("state" in error for error in errors))
        self.assertTrue(any("matchCount" in error for error in errors))
        self.assertTrue(any("expectationMet" in error for error in errors))
        self.assertTrue(any("errorCode" in error for error in errors))

    def test_sanitized_evidence_omits_error_text_and_source_path(self) -> None:
        phase = acceptance.PHASE_BY_ID["mac-seed"]
        report = self.report(phase)
        report["errorCode"] = "SECRET-PATH-OR-ACCOUNT"
        payload = acceptance.sanitized_evidence(
            report,
            phase=phase,
            source_bytes=json.dumps(report).encode(),
            captured_at=datetime(2026, 9, 2, 13, 2, tzinfo=timezone.utc),
        )

        serialized = json.dumps(payload)
        self.assertNotIn("SECRET-PATH-OR-ACCOUNT", serialized)
        self.assertNotIn("sourcePath", serialized)
        self.assertTrue(payload["probe"]["errorPresent"])

    def test_captured_evidence_rejects_unexpected_privacy_fields(self) -> None:
        phase = acceptance.PHASE_BY_ID["mac-seed"]
        report = self.report(phase)
        payload = acceptance.sanitized_evidence(
            report,
            phase=phase,
            source_bytes=json.dumps(report).encode(),
            captured_at=datetime(2026, 9, 2, 13, 2, tzinfo=timezone.utc),
        )
        payload["accountEmail"] = "must-not-be-retained@example.invalid"
        payload["probe"]["customerName"] = "must-not-be-retained"

        errors, _ = acceptance.validate_captured_evidence(
            payload,
            phase=phase,
            expected_build=self.build,
        )

        self.assertTrue(any("evidence contains unexpected keys" in error for error in errors))
        self.assertTrue(any("probe contains unexpected keys" in error for error in errors))

    def test_complete_directory_passes_and_missing_phase_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            captured_at = datetime(2026, 9, 2, 13, 2, tzinfo=timezone.utc)
            for phase in acceptance.PHASES:
                report = self.report(phase)
                payload = acceptance.sanitized_evidence(
                    report,
                    phase=phase,
                    source_bytes=json.dumps(report).encode(),
                    captured_at=captured_at,
                )
                (directory / phase.file_name).write_text(json.dumps(payload), encoding="utf-8")

            self.assertEqual(
                acceptance.validate_directory(directory, expected_build=self.build),
                [],
            )
            (directory / acceptance.PHASES[-1].file_name).unlink()
            errors = acceptance.validate_directory(directory, expected_build=self.build)
            self.assertTrue(any("missing phase evidence" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
