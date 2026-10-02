from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid

from Backend import backup_backend, billing_pdf_archive_ledger, release_data_preflight


class ReleaseDataPreflightTests(unittest.TestCase):
    def fixture(self, root: Path, *, old_pdf: bool = False,
                collision: bool = False, broken_foreign_key: bool = False,
                ready_pdf: bool = False, missing_ready_pdf: bool = False,
                created_at: datetime | None = None) -> tuple[Path, str]:
        database = root / "source.sqlite3"
        company = str(uuid.uuid4())
        attachment = str(uuid.uuid4())
        pdf_bytes = b"%PDF-verified-fixture"
        with sqlite3.connect(database) as connection:
            connection.execute("CREATE TABLE billing_publications(id TEXT PRIMARY KEY)")
            connection.execute("INSERT INTO billing_publications VALUES ('pub-1')")
            if old_pdf:
                connection.execute("""CREATE TABLE billing_pdf_archive_intents (
                    company_id TEXT NOT NULL, drive_account TEXT NOT NULL,
                    document_kind TEXT NOT NULL, document_id TEXT NOT NULL,
                    source_digest TEXT NOT NULL, renderer_version TEXT NOT NULL,
                    attachment_id TEXT NOT NULL, rendered_at TEXT NOT NULL,
                    lease_token TEXT, lease_until TEXT,
                    content_digest TEXT, drive_file_id TEXT, confirmed_link TEXT,
                    PRIMARY KEY (company_id,drive_account,document_kind,document_id,
                                 source_digest,renderer_version),
                    UNIQUE (attachment_id), UNIQUE (drive_file_id))
                """)
                rows = 2 if collision else 1
                for index in range(rows):
                    connection.execute("""INSERT INTO billing_pdf_archive_intents VALUES
                        (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL)
                    """, ("company", "account", "estimate", "document", str(index) * 64,
                          "render-v1", f"attachment-{index}", "2026-10-02T00:00:00Z"))
            if broken_foreign_key:
                connection.execute("PRAGMA foreign_keys=OFF")
                connection.execute("CREATE TABLE orphan(id TEXT REFERENCES billing_publications(id))")
                connection.execute("INSERT INTO orphan VALUES ('missing')")
            if ready_pdf or missing_ready_pdf:
                billing_pdf_archive_ledger.initialize_schema(connection)
                connection.execute("""INSERT INTO billing_pdf_archive_intents
                    (company_id,drive_account,document_kind,document_id,source_digest,
                     renderer_version,attachment_id,rendered_at,content_digest,
                     artifact_ready,artifact_bytes)
                    VALUES (?,?,?,?,?,?,?,?,?,1,?)""",
                    (company, "google-subject:" + "a" * 64, "estimate", str(uuid.uuid4()),
                     "b" * 64, "renderer-v1", attachment, "2026-10-02T00:00:00Z",
                     hashlib.sha256(pdf_bytes).hexdigest(), len(pdf_bytes)))
        storage = root / "storage"
        (storage / "billing-pdf-artifacts").mkdir(parents=True)
        (storage / "billing-pdf-artifacts" / "synthetic.pdf").write_bytes(b"%PDF-fixture")
        if ready_pdf:
            folder = storage / "billing-pdf-artifacts" / company
            folder.mkdir()
            (folder / (attachment + ".pdf")).write_bytes(pdf_bytes)
        artifact = root / "backup"
        summary = backup_backend.create_backup(database, storage, artifact,
            created_at=created_at or datetime.now(timezone.utc))
        return artifact, str(summary["artifactID"])

    def test_cli_restores_and_migrates_only_a_copy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact, artifact_id = self.fixture(root, old_pdf=True)
            original_database = backup_backend.sha256_file(artifact / backup_backend.DATABASE_FILENAME)
            scratch = root / "disposable"
            completed = subprocess.run([
                sys.executable, "-m", "Backend.release_data_preflight", "--backup", str(artifact),
                "--scratch", str(scratch), "--expected-artifact-id", artifact_id,
            ], cwd=Path(__file__).resolve().parents[1], capture_output=True, text=True, check=False)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            result = json.loads(completed.stdout)
            self.assertEqual(result["status"], "copy_verified")
            self.assertEqual(result["offHostCustody"], "operator_evidence_required")
            self.assertEqual(result["documentCount"], 1)
            self.assertGreaterEqual(result["restoreDurationSeconds"], 0)
            self.assertEqual(result["backupArtifactID"], artifact_id)
            self.assertEqual(backup_backend.sha256_file(artifact / backup_backend.DATABASE_FILENAME),
                             original_database)
            self.assertEqual(backup_backend.verify_backup(artifact)["artifactID"], artifact_id)
            with sqlite3.connect(scratch / backup_backend.DATABASE_FILENAME) as connection:
                estimate = connection.execute("SELECT name FROM sqlite_master WHERE name='billing_estimate_jobs'").fetchone()
                pdf = {row[1] for row in connection.execute("PRAGMA table_info(billing_pdf_archive_intents)")}
                retained = connection.execute("SELECT COUNT(*) FROM billing_pdf_archive_intents").fetchone()
            self.assertEqual(estimate, ("billing_estimate_jobs",))
            self.assertTrue({"artifact_ready", "artifact_bytes"} <= pdf)
            self.assertEqual(retained, (1,))

    def test_rejects_stale_or_wrong_backup_without_creating_scratch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            now = datetime.now(timezone.utc)
            artifact, artifact_id = self.fixture(root, created_at=now - timedelta(hours=25))
            scratch = root / "disposable"
            with self.assertRaisesRegex(release_data_preflight.PreflightError, "older than 24 hours"):
                release_data_preflight.run(artifact, scratch, artifact_id, now=now)
            self.assertFalse(scratch.exists())
            with self.assertRaisesRegex(release_data_preflight.PreflightError, "recorded artifact ID"):
                release_data_preflight.run(artifact, scratch, "0" * 16, now=now)
            self.assertFalse(scratch.exists())

    def test_conflicting_revisions_and_foreign_key_errors_refuse_migration(self) -> None:
        for field in ("collision", "broken_foreign_key"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                artifact, artifact_id = self.fixture(root, old_pdf=True, **{field: True})
                scratch = root / "disposable"
                with self.assertRaises(release_data_preflight.PreflightError):
                    release_data_preflight.run(artifact, scratch, artifact_id)
                self.assertEqual(backup_backend.verify_backup(artifact)["artifactID"], artifact_id)
                with sqlite3.connect(artifact / backup_backend.DATABASE_FILENAME) as connection:
                    fields = {row[1] for row in connection.execute("PRAGMA table_info(billing_pdf_archive_intents)")}
                self.assertNotIn("artifact_ready", fields)

    def test_tamper_or_scratch_overlap_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact, artifact_id = self.fixture(root)
            with self.assertRaisesRegex(release_data_preflight.PreflightError, "separate"):
                release_data_preflight.run(artifact, artifact / "scratch", artifact_id)
            (artifact / "storage" / "billing-pdf-artifacts" / "synthetic.pdf").write_bytes(b"changed")
            with self.assertRaises(backup_backend.BackupVerificationError):
                release_data_preflight.run(artifact, root / "scratch", artifact_id)
            self.assertFalse((root / "scratch").exists())

    def test_ready_pdf_must_match_restored_document_storage(self) -> None:
        for missing in (False, True):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                artifact, artifact_id = self.fixture(root, ready_pdf=not missing,
                    missing_ready_pdf=missing)
                scratch = root / "disposable"
                if missing:
                    with self.assertRaisesRegex(release_data_preflight.PreflightError,
                                                "matching stored artifact"):
                        release_data_preflight.run(artifact, scratch, artifact_id)
                else:
                    result = release_data_preflight.run(artifact, scratch, artifact_id)
                    self.assertEqual(result["readyPDFArtifactsChecked"], 1)
                self.assertEqual(backup_backend.verify_backup(artifact)["artifactID"], artifact_id)


if __name__ == "__main__":
    unittest.main()
