from datetime import datetime, timedelta, timezone
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib
import tempfile
import unittest
import uuid

from Backend import backup_backend
from Backend.billing_pdf_artifacts import BillingPDFArtifactStore
from Backend.billing_pdf_archive_ledger import (
    BillingPDFArchiveLedger,
    BillingPDFKey,
    InvalidReservation,
    ReservationBusy,
    ReservationChanged,
)


class BillingPDFArchiveLedgerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.database = Path(self.temporary.name) / "archive.sqlite"
        self.first = BillingPDFArchiveLedger(self.database)
        self.second = BillingPDFArchiveLedger(self.database)
        self.first.install()
        self.now = datetime(2026, 10, 2, 12, tzinfo=timezone.utc)
        self.key = BillingPDFKey(
            company_id=str(uuid.uuid4()),
            drive_account="google-subject:" + hashlib.sha256(b"google-subject-1").hexdigest(),
            document_kind="estimate", document_id=str(uuid.uuid4()),
            source_digest="a" * 64, renderer_version="customer-pdf-v1",
        )

    def test_two_devices_share_one_attachment_and_only_one_live_lease(self):
        first = self.first.reserve(self.key, now=self.now)
        with self.assertRaises(ReservationBusy):
            self.second.reserve(self.key, now=self.now + timedelta(seconds=1))
        self.assertEqual(self.second.read(self.key).attachment_id, first.attachment_id)
        self.assertEqual(first.key.drive_account, self.key.drive_account)
        self.assertEqual(self.second.read(self.key).key.drive_account, self.key.drive_account)
        self.assertIsNone(self.second.read(self.key).lease_token)

    def test_expired_owner_recovers_original_file_id_after_lost_response(self):
        first = self.first.reserve(self.key, now=self.now, lease_seconds=10)
        self.first.bind_content_digest(self.key, first.lease_token, "b" * 64, now=self.now)
        self.first.mark_artifact(self.key, first.lease_token, 12, now=self.now)
        self.first.bind_drive_file_id(self.key, first.lease_token, "reserved-google-id", now=self.now)
        restarted = self.second.reserve(self.key, now=self.now + timedelta(seconds=11))
        self.assertEqual(restarted.attachment_id, first.attachment_id)
        self.assertEqual(restarted.drive_file_id, "reserved-google-id")
        self.assertEqual(restarted.rendered_at, first.rendered_at)
        self.assertNotEqual(restarted.lease_token, first.lease_token)
        with self.assertRaises(ReservationChanged):
            self.first.bind_drive_file_id(self.key, first.lease_token, "new-google-id",
                                          now=self.now + timedelta(seconds=11))
        with self.assertRaises(ReservationChanged):
            self.second.bind_drive_file_id(self.key, restarted.lease_token, "new-google-id",
                                           now=self.now + timedelta(seconds=11))
        confirmed = self.second.confirm(self.key, restarted.lease_token,
            file_id="reserved-google-id", link="https://drive.google.com/file/d/reserved-google-id/view",
            content_digest="b" * 64, now=self.now + timedelta(seconds=11))
        self.assertEqual(confirmed.content_digest, "b" * 64)
        self.assertEqual(self.first.read(self.key).confirmed_link, confirmed.confirmed_link)
        after = self.first.reserve(self.key, now=self.now + timedelta(seconds=12))
        self.assertEqual(after.attachment_id, first.attachment_id)
        self.assertEqual(after.drive_file_id, "reserved-google-id")
        self.assertIsNone(after.lease_token)

    def test_conflicting_revision_cannot_create_second_drive_reservation(self):
        first = self.first.reserve(self.key, now=self.now)
        changed = BillingPDFKey(**{**self.key.__dict__, "source_digest": "c" * 64})
        changed_renderer = BillingPDFKey(**{**self.key.__dict__,
            "renderer_version": "customer-pdf-v2"})
        other_account = BillingPDFKey(**{**self.key.__dict__,
            "drive_account": "google-subject:" + hashlib.sha256(b"google-subject-2").hexdigest()})
        with self.assertRaises(ReservationChanged):
            self.second.reserve(changed, now=self.now)
        with self.assertRaises(ReservationChanged):
            self.second.reserve(changed_renderer, now=self.now)
        other_reservation = self.second.reserve(other_account, now=self.now)
        self.assertNotEqual(first.attachment_id, other_reservation.attachment_id)
        self.assertIsNone(other_reservation.drive_file_id)
        self.assertIsNone(self.second.read(changed))
        self.assertIsNone(self.second.read(changed_renderer))
        with self.first._connection() as connection:
            count = connection.execute("SELECT COUNT(*) FROM billing_pdf_archive_intents").fetchone()[0]
        self.assertEqual(count, 2)
        with self.assertRaises(ReservationChanged):
            self.second.bind_drive_file_id(other_account, first.lease_token,
                                           "first-account-id", now=self.now)

    def test_expired_or_confirmed_revision_still_blocks_divergent_device(self):
        original = self.first.reserve(self.key, now=self.now, lease_seconds=10)
        divergent = BillingPDFKey(**{**self.key.__dict__, "source_digest": "d" * 64})
        with self.assertRaises(ReservationChanged):
            self.second.reserve(divergent, now=self.now + timedelta(seconds=11))
        resumed = self.second.reserve(self.key, now=self.now + timedelta(seconds=11))
        self.assertEqual(resumed.attachment_id, original.attachment_id)
        self.second.bind_content_digest(self.key, resumed.lease_token, "b" * 64,
                                        now=self.now + timedelta(seconds=11))
        self.second.mark_artifact(self.key, resumed.lease_token, 12,
                                  now=self.now + timedelta(seconds=11))
        self.second.bind_drive_file_id(self.key, resumed.lease_token, "original-id",
                                       now=self.now + timedelta(seconds=11))
        self.second.confirm(self.key, resumed.lease_token, file_id="original-id",
            link="https://drive.google.com/file/d/original-id/view",
            content_digest="b" * 64, now=self.now + timedelta(seconds=11))
        with self.assertRaises(ReservationChanged):
            self.first.reserve(divergent, now=self.now + timedelta(seconds=12))
        self.assertIsNone(self.first.read(divergent))
        self.assertEqual(self.first.read(self.key).drive_file_id, "original-id")

    def test_two_devices_racing_divergent_sources_create_only_one_intent(self):
        divergent = BillingPDFKey(**{**self.key.__dict__, "source_digest": "e" * 64})
        with ThreadPoolExecutor(max_workers=2) as workers:
            futures = [workers.submit(ledger.reserve, key, now=self.now)
                       for ledger, key in ((self.first, self.key), (self.second, divergent))]
            outcomes = []
            for future in futures:
                try:
                    outcomes.append(future.result())
                except ReservationChanged:
                    outcomes.append(None)
        self.assertEqual(sum(value is not None for value in outcomes), 1)
        with self.first._connection() as connection:
            rows = connection.execute("SELECT source_digest FROM billing_pdf_archive_intents").fetchall()
        self.assertEqual(len(rows), 1)
        self.assertIn(rows[0]["source_digest"], {self.key.source_digest, divergent.source_digest})

    def test_confirmation_requires_saved_id_and_current_lease(self):
        reservation = self.first.reserve(self.key, now=self.now, lease_seconds=10)
        with self.assertRaises(ReservationChanged):
            self.first.confirm(self.key, reservation.lease_token, file_id="never-saved",
                link="https://drive.google.com/file/d/never-saved/view",
                content_digest="b" * 64, now=self.now)
        with self.assertRaises(ReservationChanged):
            self.first.bind_drive_file_id(self.key, reservation.lease_token, "saved-id", now=self.now)
        self.first.bind_content_digest(self.key, reservation.lease_token, "b" * 64, now=self.now)
        with self.assertRaises(ReservationChanged):
            self.first.bind_drive_file_id(self.key, reservation.lease_token, "saved-id", now=self.now)
        self.first.mark_artifact(self.key, reservation.lease_token, 12, now=self.now)
        self.first.bind_drive_file_id(self.key, reservation.lease_token, "saved-id", now=self.now)
        with self.assertRaises(ReservationChanged):
            self.first.confirm(self.key, reservation.lease_token, file_id="saved-id",
                link="https://drive.google.com/file/d/saved-id/view",
                content_digest="b" * 64, now=self.now + timedelta(seconds=10))
        with self.assertRaises(InvalidReservation):
            self.first.confirm(self.key, reservation.lease_token, file_id="saved-id",
                link="https://drive.google.com.evil/file/d/saved-id/view",
                content_digest="b" * 64, now=self.now)
        with self.assertRaises(InvalidReservation):
            self.first.confirm(self.key, reservation.lease_token, file_id="saved-id",
                link="https://drive.google.com/file/d/saved-id/view",
                content_digest="", now=self.now)
        with self.assertRaises(ReservationChanged):
            self.first.confirm(self.key, reservation.lease_token, file_id="saved-id",
                link="https://drive.google.com/file/d/saved-id/view",
                content_digest="c" * 64, now=self.now)

    def test_invalid_key_does_not_create_reservation(self):
        bad = BillingPDFKey(**{**self.key.__dict__, "source_digest": "invalid"})
        with self.assertRaises(InvalidReservation):
            self.first.reserve(bad, now=self.now)
        self.assertIsNone(self.first.read(self.key))

    def test_existing_backup_and_restore_preserve_reservation(self):
        original = self.first.reserve(self.key, now=self.now)
        pdf = b"%PDF-1.7\nbacked-up revision\n%%EOF\n"
        digest = hashlib.sha256(pdf).hexdigest()
        bound = self.first.bind_content_digest(self.key, original.lease_token, digest, now=self.now)
        storage = Path(self.temporary.name) / "storage"
        BillingPDFArtifactStore(storage).save(bound, pdf)
        self.first.mark_artifact(self.key, original.lease_token, len(pdf), now=self.now)
        self.first.bind_drive_file_id(self.key, original.lease_token, "reserved-id", now=self.now)
        artifact = Path(self.temporary.name) / "backup"
        restored = Path(self.temporary.name) / "restored"
        backup_backend.create_backup(self.database, storage, artifact)
        backup_backend.restore_drill(artifact, restored)
        recovered = BillingPDFArchiveLedger(restored / backup_backend.DATABASE_FILENAME).read(self.key)
        self.assertIsNotNone(recovered)
        self.assertEqual(recovered.attachment_id, original.attachment_id)
        self.assertEqual(recovered.drive_file_id, "reserved-id")
        self.assertTrue(recovered.artifact_ready)
        self.assertEqual(recovered.artifact_bytes, len(pdf))
        self.assertEqual(BillingPDFArtifactStore(restored / "storage").read(recovered), pdf)
        self.assertIsNone(recovered.lease_token)

    def test_existing_ledger_schema_migrates_without_claiming_artifact_ready(self):
        with self.first._connection() as connection:
            connection.execute("DROP TABLE billing_pdf_archive_intents")
            connection.execute("""
                CREATE TABLE billing_pdf_archive_intents (
                    company_id TEXT, drive_account TEXT, document_kind TEXT, document_id TEXT,
                    source_digest TEXT, renderer_version TEXT, attachment_id TEXT, rendered_at TEXT,
                    lease_token TEXT, lease_until TEXT, content_digest TEXT, drive_file_id TEXT,
                    confirmed_link TEXT,
                    PRIMARY KEY(company_id, drive_account, document_kind, document_id, source_digest, renderer_version)
                )
            """)
        self.first.install()
        reserved = self.first.reserve(self.key, now=self.now)
        self.assertFalse(reserved.artifact_ready)
        self.assertIsNone(reserved.artifact_bytes)


if __name__ == "__main__":
    unittest.main()
