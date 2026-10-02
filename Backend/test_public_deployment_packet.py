from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest

from Backend import public_deployment_packet as packet


class PublicDeploymentPacketTests(unittest.TestCase):
    @staticmethod
    def response(version: str, *, cache: str = "DYNAMIC"):
        return (200, {"content-type": "application/json", "cache-control": "no-store",
                      "cf-cache-status": cache},
                json.dumps({"status": "ok", "serviceVersion": version,
                            "time": "2026-10-02T12:00:00Z"}).encode())

    def test_matching_public_marker_never_claims_deployed_sha_or_custody(self) -> None:
        observed = datetime(2026, 10, 2, 12, 0, tzinfo=timezone.utc)
        result = packet.capture(lambda: self.response(packet.candidate_version()),
                                observed_at=observed)
        self.assertEqual(result["publicHealth"]["status"], "observed")
        self.assertTrue(result["publicHealth"]["matchesCandidateVersion"])
        self.assertEqual(result["deployedGitSHA"], "not_publicly_verifiable")
        self.assertEqual(result["renderDeploymentID"], "not_publicly_verifiable")
        self.assertEqual(result["offHostBackupCustody"], "operator_evidence_required")
        self.assertEqual(result["decision"], "NO_GO_PENDING_OPERATOR_EVIDENCE")

    def test_old_or_cached_marker_cannot_count_as_current(self) -> None:
        old = packet.capture(lambda: self.response("2026.09.18.69"))
        self.assertFalse(old["publicHealth"]["matchesCandidateVersion"])
        cached = packet.capture(lambda: self.response(packet.candidate_version(),
                                                       cache="HIT"))
        self.assertEqual(cached["publicHealth"]["status"], "unverified")
        self.assertEqual(cached["decision"], "NO_GO_PENDING_OPERATOR_EVIDENCE")

    def test_invalid_or_unavailable_health_records_no_go_without_echoing_payload(self) -> None:
        duplicate = b'{"status":"ok","status":"ok","serviceVersion":"2026.10.02.1"}'
        invalid = packet.capture(lambda: (200, {"content-type": "application/json",
                                                 "cache-control": "no-store"}, duplicate))
        self.assertEqual(invalid["publicHealth"], {"status": "unavailable"})
        self.assertNotIn("serviceVersion", invalid["publicHealth"])
        unavailable = packet.capture(lambda: (_ for _ in ()).throw(packet.PacketError("private detail")))
        self.assertEqual(unavailable["publicHealth"], {"status": "unavailable"})
        self.assertNotIn("private detail", json.dumps(unavailable))

    def test_data_report_is_consistency_evidence_not_off_host_proof(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "data-report.json"
            report.write_text(json.dumps({
                "status": "copy_verified", "serviceVersion": packet.candidate_version(),
                "backupArtifactID": "a" * 16, "restoreDrill": "verified",
                "migrationCopy": "verified", "offHostCustody": "operator_evidence_required",
            }), encoding="utf-8")
            result = packet.capture(lambda: self.response(packet.candidate_version()),
                                    data_report=report)
            self.assertEqual(result["dataCopyPreflight"]["status"],
                             "report_consistent_source_unverified")
            self.assertEqual(result["offHostBackupCustody"], "operator_evidence_required")
            report.write_text(json.dumps({"status": "copy_verified",
                                          "serviceVersion": "2026.09.18.69"}), encoding="utf-8")
            with self.assertRaises(packet.PacketError):
                packet.capture(lambda: self.response(packet.candidate_version()),
                               data_report=report)

    def test_packet_output_refuses_overwrite_or_escape_from_temp(self) -> None:
        result = packet.capture(lambda: self.response(packet.candidate_version()))
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "public-packet.json"
            packet._write_new(destination, result)
            self.assertEqual(json.loads(destination.read_text(encoding="utf-8")), result)
            with self.assertRaises(packet.PacketError):
                packet._write_new(destination, result)
        with self.assertRaises(packet.PacketError):
            packet._write_new(Path.cwd() / "forbidden-packet.json", result)

    def test_system_tmp_alias_is_allowed(self) -> None:
        self.assertTrue(packet._in_temporary_directory(Path("/tmp") / "packet.json"))
        if Path("/private/tmp").resolve() == Path("/tmp").resolve():
            self.assertTrue(packet._in_temporary_directory(Path("/private/tmp") / "packet.json"))


if __name__ == "__main__":
    unittest.main()
