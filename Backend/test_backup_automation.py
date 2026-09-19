from __future__ import annotations

import json
import os
import tempfile
import threading
import unittest
from collections import namedtuple
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from Backend import backup_backend
from Backend import gunnaire_backend as backend
from Backend import gunnaire_local_ai_backend as deployment_backend


DiskUsage = namedtuple("DiskUsage", "total used free")
AUTO_PREFIX = "gunnaire-auto-backup-"


class BackupAutomationTests(unittest.TestCase):
    def configuration(self, root: Path, **overrides: object) -> mock._patch_dict:
        settings: dict[str, object] = dict(
            DATA_ROOT=root,
            DB_PATH=root / "gunnaire_backend.sqlite3",
            STORAGE_ROOT=root / "storage",
            BACKUP_STATUS_PATH=root / "backup_status.json",
            BACKUP_AUTOMATION_STATUS_PATH=root / "backup_automation.json",
            BACKUP_DIRECTORY=root / "backups",
            BACKUP_AUTOMATION_ENABLED=True,
            BACKUP_INTERVAL_HOURS=20,
            BACKUP_RETAIN_COUNT=2,
        )
        settings.update(overrides)
        return mock.patch.multiple(backend, **settings)

    def seed_live_data(self) -> None:
        backend.initialize_database()
        documents = backend.STORAGE_ROOT / "documents" / "2026-09-16"
        documents.mkdir(parents=True)
        (documents / "abc-report.pdf").write_bytes(b"fictional report bytes")

    def run_at(self, now: datetime) -> dict[str, object]:
        """Run the scheduler with the verification clock pinned to `now`."""
        with mock.patch.object(backup_backend, "utc_now", return_value=now):
            return backend.run_scheduled_backup_if_due(now=now)

    def artifact_ids(self, root: Path) -> list[str]:
        return [
            backup_backend.verify_backup(artifact)["artifactID"]
            for artifact in backend.scheduled_backup_artifacts(root / "backups")
        ]

    def test_first_run_creates_a_verified_artifact_and_readiness_turns_ready(self) -> None:
        now = datetime(2026, 9, 16, 20, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root):
                self.seed_live_data()

                result = self.run_at(now)
                artifacts = backend.scheduled_backup_artifacts(root / "backups")
                component = backend.backup_readiness_component(now=now + timedelta(minutes=5))

                self.assertEqual(result["outcome"], "verified")
                self.assertEqual(len(artifacts), 1)
                self.assertTrue(artifacts[0].name.startswith(f"{AUTO_PREFIX}20260916T200000"))
                verified = backup_backend.verify_backup(artifacts[0])
                self.assertEqual(verified["artifactID"], result["artifactID"])
                self.assertEqual(verified["documentCount"], 1)
                status = json.loads((root / "backup_status.json").read_text(encoding="utf-8"))
                self.assertEqual(status["artifactID"], result["artifactID"])
                self.assertEqual(status["verifiedAt"], now.isoformat())
                automation = json.loads((root / "backup_automation.json").read_text(encoding="utf-8"))
                self.assertEqual(automation["outcome"], "verified")
                self.assertEqual(automation["pruned"], 0)
                self.assertEqual(automation["swept"], 0)
                self.assertNotIn("pruneError", automation)
        self.assertEqual(component["status"], "ready")
        self.assertIn("was verified 0.1 hours ago; retain a copy off-host.", component["detail"])
        self.assertIn("Automatic in-service backups run every 20 hours and keep the newest 2.", component["detail"])
        self.assertNotIn(str(root), component["detail"])

    def test_a_fresh_backup_is_not_repeated_until_the_interval_elapses(self) -> None:
        first_at = datetime(2026, 9, 16, 20, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root):
                self.seed_live_data()

                first = self.run_at(first_at)
                early = self.run_at(first_at + timedelta(hours=19, minutes=59))
                artifacts_after_early = len(backend.scheduled_backup_artifacts(root / "backups"))
                due = self.run_at(first_at + timedelta(hours=20))
                artifacts_after_due = len(backend.scheduled_backup_artifacts(root / "backups"))

        self.assertEqual(first["outcome"], "verified")
        self.assertEqual(early["outcome"], "fresh")
        self.assertAlmostEqual(float(early["ageHours"]), 19.98, places=2)
        self.assertEqual(artifacts_after_early, 1)
        self.assertEqual(due["outcome"], "verified")
        self.assertNotEqual(due["artifactID"], first["artifactID"])
        self.assertEqual(artifacts_after_due, 2)

    def test_retention_keeps_only_the_newest_artifacts(self) -> None:
        base = datetime(2026, 9, 10, 20, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root):
                self.seed_live_data()

                ids = [self.run_at(base + timedelta(hours=20 * index))["artifactID"] for index in range(4)]
                kept = self.artifact_ids(root)
                automation = json.loads((root / "backup_automation.json").read_text(encoding="utf-8"))

        self.assertEqual(len(set(ids)), 4)
        self.assertEqual(kept, [ids[3], ids[2]])
        self.assertEqual(automation["pruned"], 1)

    def test_rotation_frees_space_before_the_space_check(self) -> None:
        """A disk filled by old artifacts is recovered by retention, not stuck behind the guard."""
        base = datetime(2026, 9, 10, 20, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root, BACKUP_RETAIN_COUNT=5):
                self.seed_live_data()
                for index in range(3):
                    self.assertEqual(self.run_at(base + timedelta(hours=20 * index))["outcome"], "verified")
                self.assertEqual(len(backend.scheduled_backup_artifacts(root / "backups")), 3)

            def usage(path: object) -> DiskUsage:
                # Free space exists only once at most one old artifact remains.
                remaining = len(backend.scheduled_backup_artifacts(root / "backups"))
                return DiskUsage(10**12, 0, 10**12 if remaining <= 1 else 0)

            with self.configuration(root, BACKUP_RETAIN_COUNT=2):
                with mock.patch.object(backend.shutil, "disk_usage", side_effect=usage):
                    result = self.run_at(base + timedelta(hours=60))
                kept = self.artifact_ids(root)
                automation = json.loads((root / "backup_automation.json").read_text(encoding="utf-8"))

        self.assertEqual(result["outcome"], "verified")
        self.assertEqual(len(kept), 2)
        self.assertEqual(kept[0], result["artifactID"])
        self.assertEqual(automation["pruned"], 2)

    def test_pruning_never_removes_the_artifact_readiness_cites(self) -> None:
        base = datetime(2026, 9, 10, 20, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root, BACKUP_RETAIN_COUNT=5):
                self.seed_live_data()
                older = self.run_at(base)["artifactID"]
                newer = self.run_at(base + timedelta(hours=20))["artifactID"]

                protected_removed = backend.prune_scheduled_backups(root / "backups", keep=1, protect={older})
                remaining_protected = len(backend.scheduled_backup_artifacts(root / "backups"))
                unprotected_removed = backend.prune_scheduled_backups(root / "backups", keep=1, protect={newer})
                remaining = self.artifact_ids(root)

        self.assertEqual(protected_removed, 0)
        self.assertEqual(remaining_protected, 2)
        self.assertEqual(unprotected_removed, 1)
        self.assertEqual(remaining, [newer])

    def test_a_run_protects_the_artifact_the_status_file_cites_even_when_it_is_oldest(self) -> None:
        base = datetime(2026, 9, 10, 20, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root, BACKUP_RETAIN_COUNT=1):
                self.seed_live_data()
                cited = self.run_at(base)["artifactID"]
                cited_status = (root / "backup_status.json").read_text(encoding="utf-8")
                self.run_at(base + timedelta(hours=20))
                # An operator restored the status record pointing at the first artifact.
                (root / "backup_status.json").write_text(cited_status, encoding="utf-8")
                # Age it past the interval so a new run happens.
                self.run_at(base + timedelta(hours=40))
                remaining = self.artifact_ids(root)

        self.assertIn(cited, remaining)
        self.assertEqual(len(remaining), 2)

    def test_pruning_ignores_directories_the_worker_did_not_create(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            backups = root / "backups"
            operator = backups / "gunnaire-backup-20260901-120000"
            operator.mkdir(parents=True)
            (operator / backup_backend.MANIFEST_FILENAME).write_text("{}", encoding="utf-8")
            (backups / f"{AUTO_PREFIX}20260901T000000000000Z").mkdir()  # no manifest: never a retention candidate
            (backups / "operator-copy").mkdir()
            (backups / "operator-copy" / backup_backend.MANIFEST_FILENAME).write_text("{}", encoding="utf-8")

            removed = backend.prune_scheduled_backups(backups, keep=0, protect=set())

            self.assertEqual(removed, 0)
            self.assertTrue(operator.is_dir())
            self.assertTrue((backups / f"{AUTO_PREFIX}20260901T000000000000Z").is_dir())
            self.assertTrue((backups / "operator-copy").is_dir())

    def test_partial_artifacts_from_a_dead_process_are_swept_once_stale(self) -> None:
        now = datetime(2026, 9, 16, 20, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root):
                self.seed_live_data()
                backups = root / "backups"
                stale = backups / f"{AUTO_PREFIX}20260916T120000000000Z"
                (stale / "storage").mkdir(parents=True)
                (stale / backup_backend.DATABASE_FILENAME).write_bytes(b"half a copy")
                old = now.timestamp() - 7 * 3600
                for path in (stale / "storage", stale / backup_backend.DATABASE_FILENAME, stale):
                    os.utime(path, (old, old))
                fresh = backups / f"{AUTO_PREFIX}20260916T195900000000Z"
                fresh.mkdir()
                recent = now.timestamp() - 60
                os.utime(fresh, (recent, recent))
                operator_partial = backups / "gunnaire-backup-20260901-120000"
                operator_partial.mkdir()
                os.utime(operator_partial, (old, old))

                result = self.run_at(now)
                automation = json.loads((root / "backup_automation.json").read_text(encoding="utf-8"))

                self.assertEqual(result["outcome"], "verified")
                self.assertEqual(result["swept"], 1)
                self.assertEqual(automation["swept"], 1)
                self.assertFalse(stale.exists())
                self.assertTrue(fresh.is_dir())
                self.assertTrue(operator_partial.is_dir())

    def test_insufficient_free_space_is_recorded_for_readiness_without_writing_an_artifact(self) -> None:
        now = datetime(2026, 9, 16, 20, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root):
                self.seed_live_data()
                with mock.patch.object(backend.shutil, "disk_usage", return_value=DiskUsage(1, 1, 0)):
                    result = self.run_at(now)
                artifacts = backend.scheduled_backup_artifacts(root / "backups")
                status_exists = (root / "backup_status.json").exists()
                automation = json.loads((root / "backup_automation.json").read_text(encoding="utf-8"))
                component = backend.backup_readiness_component(now=now)

        self.assertEqual(result["outcome"], "failed")
        self.assertEqual(
            result["error"],
            "BackupVerificationError: Insufficient free disk space for a verified backup; "
            "free space or retain fewer backups.",
        )
        self.assertEqual(artifacts, [])
        self.assertFalse(status_exists)
        self.assertEqual(automation["outcome"], "failed")
        self.assertEqual(automation["attemptedAt"], now.isoformat())
        self.assertEqual(component["status"], "attention")
        self.assertIn(
            "The last automatic attempt failed at 2026-09-16T20:00:00+00:00: "
            "BackupVerificationError: Insufficient free disk space",
            component["detail"],
        )
        self.assertNotIn(str(root), component["detail"])

    def test_failure_descriptions_never_include_paths_or_filenames(self) -> None:
        now = datetime(2026, 9, 16, 20, 0, tzinfo=timezone.utc)
        verification_error = backup_backend.BackupVerificationError(
            "Backup file verification failed: storage/documents/2026-09-16/abc-report.pdf"
        )
        os_error = OSError(28, "No space left on device", "/var/data/backups/gunnaire-auto-backup-x")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root):
                self.seed_live_data()
                outcomes = []
                for error in (verification_error, os_error):
                    with mock.patch.object(backend.backup_backend, "create_backup", side_effect=error):
                        outcomes.append(self.run_at(now))
                automation = json.loads((root / "backup_automation.json").read_text(encoding="utf-8"))

        self.assertEqual(outcomes[0]["error"], "BackupVerificationError: Backup file verification failed")
        self.assertEqual(outcomes[1]["error"], "OSError errno 28")
        self.assertEqual(automation["error"], "OSError errno 28")

    def test_a_status_write_failure_keeps_the_verified_artifact(self) -> None:
        now = datetime(2026, 9, 16, 20, 0, tzinfo=timezone.utc)
        original = backup_backend.write_json_atomic

        def write(path: Path, payload: dict[str, object]) -> None:
            if path.name == "backup_status.json":
                raise OSError(13, "Permission denied", str(path))
            original(path, payload)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root):
                self.seed_live_data()
                with mock.patch.object(backup_backend, "write_json_atomic", side_effect=write):
                    result = self.run_at(now)
                artifacts = backend.scheduled_backup_artifacts(root / "backups")
                self.assertEqual(len(artifacts), 1)
                verified = backup_backend.verify_backup(artifacts[0])
                status_exists = (root / "backup_status.json").exists()
                automation = json.loads((root / "backup_automation.json").read_text(encoding="utf-8"))

        self.assertEqual(result, {"outcome": "failed", "error": "OSError errno 13"})
        self.assertEqual(verified["documentCount"], 1)
        self.assertFalse(status_exists)
        self.assertEqual(automation["outcome"], "failed")

    def test_a_rotation_failure_after_a_verified_backup_keeps_the_verified_outcome(self) -> None:
        now = datetime(2026, 9, 16, 20, 0, tzinfo=timezone.utc)
        original = backend.scheduled_backup_artifacts
        calls = {"count": 0}

        def listing(directory: Path) -> list[Path]:
            calls["count"] += 1
            if calls["count"] == 2:  # the rotation after create_backup
                raise OSError(5, "Input/output error", str(directory))
            return original(directory)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root):
                self.seed_live_data()
                with mock.patch.object(backend, "scheduled_backup_artifacts", side_effect=listing):
                    result = self.run_at(now)
                automation = json.loads((root / "backup_automation.json").read_text(encoding="utf-8"))
                component = backend.backup_readiness_component(now=now)

        self.assertEqual(result["outcome"], "verified")
        self.assertEqual(automation["outcome"], "verified")
        self.assertEqual(automation["pruneError"], "OSError errno 5")
        self.assertEqual(component["status"], "ready")

    def test_readiness_probe_files_are_never_copied_or_counted(self) -> None:
        now = datetime(2026, 9, 16, 20, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root):
                self.seed_live_data()
                (backend.STORAGE_ROOT / ".gunnaire-readiness-probe123").write_bytes(b"x" * 4096)
                counted = backend.scheduled_backup_data_bytes()
                result = self.run_at(now)
                artifact = backend.scheduled_backup_artifacts(root / "backups")[0]
                copied = sorted(path.name for path in (artifact / "storage").rglob("*") if path.is_file())
                verified = backup_backend.verify_backup(artifact)

                expected_bytes = backend.DB_PATH.stat().st_size + len(b"fictional report bytes")

        self.assertEqual(result["outcome"], "verified")
        self.assertEqual(copied, ["abc-report.pdf"])
        self.assertEqual(verified["documentCount"], 1)
        self.assertEqual(counted, expected_bytes)

    def test_automation_can_be_switched_off(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root, BACKUP_AUTOMATION_ENABLED=False):
                self.seed_live_data()
                result = backend.run_scheduled_backup_if_due()
                worker = backend.start_backup_worker()
                component = backend.backup_readiness_component()

        self.assertEqual(result, {"outcome": "disabled"})
        self.assertIsNone(worker)
        self.assertEqual(component["status"], "attention")
        self.assertTrue(component["detail"].endswith("Automatic in-service backups are off."))

    def test_a_backup_already_in_progress_is_not_duplicated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root):
                self.seed_live_data()
                backend.BACKUP_LOCK.acquire()
                try:
                    result = backend.run_scheduled_backup_if_due()
                finally:
                    backend.BACKUP_LOCK.release()
                artifacts = backend.scheduled_backup_artifacts(root / "backups")

        self.assertEqual(result, {"outcome": "busy"})
        self.assertEqual(artifacts, [])

    def test_a_naive_clock_yields_the_attention_component_instead_of_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root):
                (root / "backup_status.json").write_text(
                    json.dumps({"artifactID": "abcdef0123456789", "verifiedAt": "2026-09-16T20:00:00+00:00"}),
                    encoding="utf-8",
                )
                component = backend.backup_readiness_component(now=datetime(2026, 9, 16, 20, 30))
                age = backend.verified_backup_age_hours(datetime(2026, 9, 16, 20, 30))

        self.assertEqual(component["status"], "attention")
        self.assertTrue(component["detail"].startswith("No recent verified backup record is available"))
        self.assertIsNone(age)

    def test_worker_thread_runs_the_scheduler_and_stops_on_request(self) -> None:
        ran = threading.Event()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root, BACKUP_WORKER_STARTUP_DELAY_SECONDS=0, BACKUP_WORKER_CHECK_SECONDS=30):
                with mock.patch.object(
                    backend, "run_scheduled_backup_if_due",
                    side_effect=lambda *args, **kwargs: (ran.set(), {"outcome": "fresh"})[1],
                ):
                    worker = backend.start_backup_worker()
                    try:
                        self.assertIsNotNone(worker)
                        self.assertEqual(worker.name, "gunnaire-backup-worker")
                        self.assertTrue(worker.daemon)
                        self.assertTrue(ran.wait(5))
                    finally:
                        backend.BACKUP_WORKER_STOP_EVENT.set()
                        backend.BACKUP_WAKE_EVENT.set()
                        worker.join(5)
                        backend.BACKUP_WAKE_EVENT.clear()
                        backend.BACKUP_WORKER_STOP_EVENT.clear()
        self.assertFalse(worker.is_alive())

    def test_deployed_entrypoint_starts_the_backup_worker_after_the_database(self) -> None:
        order: list[str] = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configuration(root, AUTH_MODE="google-id-token"):
                with mock.patch.object(deployment_backend, "ThreadingHTTPServer") as server, \
                        mock.patch.object(backend, "initialize_database", side_effect=lambda: order.append("db")), \
                        mock.patch.object(backend, "start_push_delivery_worker", side_effect=lambda: order.append("push")), \
                        mock.patch.object(backend, "start_backup_worker", side_effect=lambda: order.append("backup")), \
                        mock.patch.object(backend, "configure_live_logging", side_effect=lambda: order.append("logging")):
                    server.return_value.serve_forever.return_value = None
                    with mock.patch("builtins.print"):
                        deployment_backend.main()

        self.assertEqual(order, ["logging", "db", "push", "backup"])
        server.return_value.serve_forever.assert_called_once()

    def test_interval_default_stays_inside_the_readiness_target(self) -> None:
        self.assertLess(backend.BACKUP_INTERVAL_HOURS, backend.BACKUP_MAX_AGE_HOURS)
        self.assertGreaterEqual(backend.BACKUP_WORKER_CHECK_SECONDS, 30)
        self.assertLessEqual(
            backend.BACKUP_INTERVAL_HOURS * 3600 + backend.BACKUP_WORKER_CHECK_SECONDS,
            backend.BACKUP_MAX_AGE_HOURS * 3600,
        )


if __name__ == "__main__":
    unittest.main()
