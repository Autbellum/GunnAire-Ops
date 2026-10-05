from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from Backend import backup_backend


class BackupBackendTests(unittest.TestCase):
    def create_source(self, root: Path) -> tuple[Path, Path]:
        database = root / "source.sqlite3"
        with closing(sqlite3.connect(database)) as connection, connection:
            connection.execute("CREATE TABLE jobs(id TEXT PRIMARY KEY, summary TEXT NOT NULL)")
            connection.execute("INSERT INTO jobs VALUES ('job-1', 'Verified service visit')")
        storage = root / "storage"
        (storage / "jobs" / "job-1").mkdir(parents=True)
        (storage / "jobs" / "job-1" / "report.pdf").write_bytes(b"fictional report bytes")
        (storage / "receipt.jpg").write_bytes(b"fictional receipt bytes")
        return database, storage

    def test_backup_closes_source_when_destination_cannot_open(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database, storage = self.create_source(root)
            artifact = root / "failed-backup"
            with closing(sqlite3.connect(database)) as source:
                with mock.patch.object(backup_backend.sqlite3, "connect", side_effect=[
                    source, sqlite3.OperationalError("synthetic destination failure")
                ]):
                    with self.assertRaisesRegex(sqlite3.OperationalError, "synthetic destination failure"):
                        backup_backend.create_backup(database, storage, artifact)
                with self.assertRaises(sqlite3.ProgrammingError):
                    source.execute("SELECT 1")
            self.assertFalse(artifact.exists())

    def test_backup_closes_source_even_when_destination_close_fails(self) -> None:
        class FailingCloseConnection(sqlite3.Connection):
            def close(self) -> None:
                super().close()
                raise sqlite3.OperationalError("synthetic close failure")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database, storage = self.create_source(root)
            artifact = root / "failed-backup"
            destination = sqlite3.connect(":memory:", factory=FailingCloseConnection)
            try:
                with closing(sqlite3.connect(database)) as source:
                    with mock.patch.object(backup_backend.sqlite3, "connect", side_effect=[source, destination]):
                        with self.assertRaisesRegex(sqlite3.OperationalError, "synthetic close failure"):
                            backup_backend.create_backup(database, storage, artifact)
                    with self.assertRaises(sqlite3.ProgrammingError):
                        source.execute("SELECT 1")
                    with self.assertRaises(sqlite3.ProgrammingError):
                        destination.execute("SELECT 1")
            finally:
                sqlite3.Connection.close(destination)
            self.assertFalse(artifact.exists())

    def test_backup_verifies_database_documents_and_readiness_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database, storage = self.create_source(root)
            artifact = root / "off-host" / "backup-001"
            state_file = root / "backup_status.json"

            summary = backup_backend.create_backup(
                database,
                storage,
                artifact,
                state_file=state_file,
                created_at=datetime(2026, 8, 26, 20, 0, tzinfo=timezone.utc),
            )
            verified = backup_backend.verify_backup(artifact)
            state = json.loads(state_file.read_text(encoding="utf-8"))

            self.assertEqual(summary, verified)
            self.assertEqual(summary["documentCount"], 2)
            self.assertEqual(state["artifactID"], summary["artifactID"])
            self.assertGreater(summary["databaseBytes"], 0)

    def test_verification_rejects_a_tampered_document(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database, storage = self.create_source(root)
            artifact = root / "backup-002"
            backup_backend.create_backup(database, storage, artifact)
            (artifact / "storage" / "receipt.jpg").write_bytes(b"tampered")

            with self.assertRaises(backup_backend.BackupVerificationError):
                backup_backend.verify_backup(artifact)

    def test_restore_drill_refuses_overwrite_and_preserves_queryable_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database, storage = self.create_source(root)
            artifact = root / "backup-003"
            restored = root / "restore-drill"
            backup_backend.create_backup(database, storage, artifact)

            summary = backup_backend.restore_drill(artifact, restored)
            with closing(sqlite3.connect(restored / backup_backend.DATABASE_FILENAME)) as connection:
                job = connection.execute("SELECT summary FROM jobs WHERE id = 'job-1'").fetchone()

            self.assertEqual(job, ("Verified service visit",))
            self.assertTrue((restored / "restore_drill.json").is_file())
            self.assertEqual(summary["documentCount"], 2)
            with self.assertRaises(backup_backend.BackupVerificationError):
                backup_backend.restore_drill(artifact, restored)


if __name__ == "__main__":
    unittest.main()
