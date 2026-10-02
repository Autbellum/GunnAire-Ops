import hashlib
from pathlib import Path
import tempfile
import unittest
import uuid

from Backend.billing_pdf_archive_ledger import BillingPDFArchiveLedger, BillingPDFKey
from Backend.billing_pdf_artifacts import ArtifactError, BillingPDFArtifactStore
from Backend import backup_backend
from datetime import datetime, timezone


class BillingPDFArtifactStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.store = BillingPDFArtifactStore(self.root / "storage")
        self.ledger = BillingPDFArchiveLedger(self.root / "ledger.sqlite")
        self.ledger.install()
        self.pdf = b"%PDF-1.7\nfixture billing revision\n%%EOF\n"
        self.digest = hashlib.sha256(self.pdf).hexdigest()
        self.key = BillingPDFKey(str(uuid.uuid4()), "google-subject:" + "a" * 64,
            "estimate", str(uuid.uuid4()), "b" * 64, "customer-pdf-v1")
        self.now = datetime(2026, 10, 2, tzinfo=timezone.utc)
        reserved = self.ledger.reserve(self.key, now=self.now)
        self.reservation = self.ledger.bind_content_digest(self.key, reserved.lease_token,
            self.digest, now=self.now)

    def test_two_devices_and_relaunch_adopt_one_exact_artifact(self):
        self.assertEqual(self.store.save(self.reservation, self.pdf), (len(self.pdf), self.digest))
        second_device = BillingPDFArtifactStore(self.root / "storage")
        self.assertEqual(second_device.save(self.reservation, self.pdf), (len(self.pdf), self.digest))
        self.assertEqual(second_device.read(self.reservation), self.pdf)
        files = list((self.root / "storage").rglob("*.pdf"))
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].name, self.reservation.attachment_id + ".pdf")

    def test_wrong_revision_bytes_do_not_change_original(self):
        self.store.save(self.reservation, self.pdf)
        with self.assertRaises(ArtifactError):
            self.store.save(self.reservation, b"%PDF-1.7\nother\n")
        self.assertEqual(self.store.read(self.reservation), self.pdf)

    def test_missing_digest_and_non_pdf_rejected_before_write(self):
        raw = self.ledger.read(self.key)
        self.assertEqual(raw.content_digest, self.digest)
        with self.assertRaises(ArtifactError):
            self.store.save(raw, b"not a PDF")
        self.assertEqual(list((self.root / "storage").rglob("*.pdf")), [])

    def test_tamper_and_symlink_fail_closed(self):
        self.store.save(self.reservation, self.pdf)
        target = next((self.root / "storage").rglob("*.pdf"))
        target.write_bytes(b"%PDF-1.7\ntampered\n")
        with self.assertRaises(ArtifactError):
            self.store.read(self.reservation)
        with self.assertRaises(ArtifactError):
            self.store.save(self.reservation, self.pdf)
        target.unlink()
        target.symlink_to(self.root / "outside.pdf")
        with self.assertRaises(ArtifactError):
            self.store.save(self.reservation, self.pdf)

    def test_symlinked_company_directory_rejected(self):
        root = self.root / "storage" / "billing-pdf-artifacts"
        root.mkdir(parents=True)
        (root / self.key.company_id).symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ArtifactError):
            self.store.save(self.reservation, self.pdf)

    def test_verified_backup_and_restore_retains_exact_server_artifact(self):
        self.store.save(self.reservation, self.pdf)
        folder = next((self.root / "storage" / "billing-pdf-artifacts").iterdir())
        partial = folder / ("." + self.reservation.attachment_id + "-" + "a" * 32 + ".part")
        partial.write_bytes(b"partial content must never enter backup")
        backup = self.root / "backup"
        summary = backup_backend.create_backup(self.root / "ledger.sqlite",
            self.root / "storage", backup)
        self.assertEqual(summary["documentCount"], 1)
        restored = self.root / "restore"
        backup_backend.restore_drill(backup, restored)
        recovered = BillingPDFArtifactStore(restored / "storage")
        self.assertEqual(recovered.read(self.reservation), self.pdf)

    def test_partial_file_name_cannot_hide_a_backup_symlink(self):
        self.store.save(self.reservation, self.pdf)
        folder = next((self.root / "storage" / "billing-pdf-artifacts").iterdir())
        partial = folder / ("." + self.reservation.attachment_id + "-" + "a" * 32 + ".part")
        partial.symlink_to(self.root / "outside.pdf")
        with self.assertRaises(backup_backend.BackupVerificationError):
            backup_backend.create_backup(self.root / "ledger.sqlite",
                self.root / "storage", self.root / "backup")


if __name__ == "__main__":
    unittest.main()
