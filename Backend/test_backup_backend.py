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
    def test_private_upload_namespace_mode_survives_synthetic_backup(self):
        import stat
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database, storage = self.create_source(root)
            private = storage / '.document-upload-v1'
            private.mkdir(mode=0o700)
            (private / 'synthetic.payload').write_bytes(b'synthetic pending bytes')
            (private / 'synthetic.payload').chmod(0o600)
            artifact = root / 'backups'
            backup_backend.create_backup(database, storage, artifact)
            copied = artifact / 'storage' / private.name
            self.assertEqual(stat.S_IMODE(copied.stat().st_mode), 0o700)
            self.assertEqual((copied / 'synthetic.payload').read_bytes(), b'synthetic pending bytes')

    def test_private_setgid_namespace_survives_synthetic_backup(self):
        import stat
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);database,storage=self.create_source(root)
            private=storage/'.document-upload-v1';private.mkdir();private.chmod(0o2700)
            payload=private/'synthetic.payload';payload.write_bytes(b'synthetic pending');payload.chmod(0o600)
            artifact=root/'backup';backup_backend.create_backup(database,storage,artifact)
            copied=artifact/'storage'/private.name
            self.assertEqual(stat.S_IMODE(copied.stat().st_mode),0o2700)
            self.assertEqual(stat.S_IMODE((copied/payload.name).stat().st_mode),0o600)
            self.assertEqual((copied/payload.name).read_bytes(),payload.read_bytes())

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

    def test_backup_copy_syncs_before_releasing_cache_and_preserves_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, target = root / "source", root / "target"
            source.write_bytes(b"original" * 1000)
            events = []
            with mock.patch.object(backup_backend.os, "fsync", side_effect=lambda fd: events.append("sync")), mock.patch.object(backup_backend.os, "posix_fadvise", side_effect=lambda *args: events.append("release"), create=True), mock.patch.object(backup_backend.os, "POSIX_FADV_DONTNEED", 4, create=True):
                backup_backend.copy_document(source, target)
            self.assertEqual(events, ["sync", "release", "release"])
            self.assertEqual(source.read_bytes(), target.read_bytes())
            self.assertEqual(source.stat().st_mtime_ns, target.stat().st_mtime_ns)
            with mock.patch.object(backup_backend.os, "fsync", side_effect=OSError("sync failed")):
                with self.assertRaises(OSError): backup_backend.copy_document(source, root / "failed")
            self.assertEqual(source.read_bytes(), b"original" * 1000)

    def test_hash_releases_cache_but_advice_failure_preserves_digest(self):
        import hashlib
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "file"
            path.write_bytes(b"immutable")
            for failure in [None, OSError("unsupported")]:
                with mock.patch.object(backup_backend.os, "posix_fadvise", side_effect=failure, create=True) as advice, mock.patch.object(backup_backend.os, "POSIX_FADV_DONTNEED", 4, create=True):
                    self.assertEqual(backup_backend.sha256_file(path), hashlib.sha256(b"immutable").hexdigest())
                    advice.assert_called_once()
            self.assertEqual(path.read_bytes(), b"immutable")

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
