import hashlib
import unittest
import uuid

from Backend.billing_pdf_archive_ledger import BillingPDFKey, BillingPDFReservation
from Backend.billing_pdf_drive_upload import BillingPDFDriveUpload, ProviderUploadError


class UploadTests(unittest.TestCase):
    def setUp(self):
        self.pdf = b"%PDF-1.7\nfixed synthetic PDF\n%%EOF\n"
        self.key = BillingPDFKey(str(uuid.uuid4()), "google-subject:" + "a" * 64,
                                 "estimate", str(uuid.uuid4()), "b" * 64, "customer-pdf-v1")
        self.reservation = BillingPDFReservation(self.key, str(uuid.uuid4()), "2026-10-02T00:00:00+00:00",
            str(uuid.uuid4()), "2026-10-02T00:05:00+00:00", hashlib.sha256(self.pdf).hexdigest(),
            "reserved-id", None, True, len(self.pdf))

    def test_generated_id_and_exact_multipart_metadata(self):
        calls = []
        def send(request, **kwargs):
            calls.append(request)
            if request.get_method() == "GET":
                return 200, {"ids": ["reserved-id"], "space": "drive"}
            return 201, {"id": "reserved-id"}
        uploader = BillingPDFDriveUpload(send)
        self.assertEqual(uploader.generate_id("synthetic-token"), "reserved-id")
        self.assertEqual(uploader.create(self.key, self.reservation, self.pdf, "synthetic-token"), "reserved-id")
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0].full_url,
            "https://www.googleapis.com/drive/v3/files/generateIds?count=1&space=drive&type=files")
        self.assertEqual(calls[1].full_url,
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")
        body = calls[1].data
        self.assertEqual(body.count(self.pdf), 1)
        self.assertIn(b'"id":"reserved-id"', body)
        self.assertIn(('"gunnaireContentSHA256":"' + self.reservation.content_digest + '"').encode(), body)
        self.assertIn(('"gunnaireCompanyID":"' + self.key.company_id + '"').encode(), body)

    def test_conflict_is_reconcilable_but_other_id_and_uncertain_reply_are_not(self):
        self.assertEqual(BillingPDFDriveUpload(lambda request: (409, None)).create(
            self.key, self.reservation, self.pdf, "synthetic-token"), "reserved-id")
        for result in ((201, {"id": "other"}), (200, {}), (500, None)):
            with self.subTest(result=result), self.assertRaises(ProviderUploadError):
                BillingPDFDriveUpload(lambda request: result).create(
                    self.key, self.reservation, self.pdf, "synthetic-token")

    def test_changed_bytes_and_missing_artifact_refuse_before_network(self):
        def forbidden(request):
            self.fail("Provider must not be contacted")
        uploader = BillingPDFDriveUpload(forbidden)
        for data in (b"%PDF-bad", self.pdf + b"changed"):
            with self.assertRaises(ProviderUploadError):
                uploader.create(self.key, self.reservation, data, "synthetic-token")
        missing = BillingPDFReservation(self.key, self.reservation.attachment_id, self.reservation.rendered_at,
            self.reservation.lease_token, self.reservation.lease_until, self.reservation.content_digest,
            self.reservation.drive_file_id, None, False, len(self.pdf))
        with self.assertRaises(ProviderUploadError):
            uploader.create(self.key, missing, self.pdf, "synthetic-token")

    def test_invalid_generated_id_and_token_refuse(self):
        for value in ({"ids": ["bad/id"], "space": "drive"}, {"ids": [], "space": "drive"},
                      {"ids": ["id"], "space": "appDataFolder"}):
            with self.subTest(value=value), self.assertRaises(ProviderUploadError):
                BillingPDFDriveUpload(lambda request: (200, value)).generate_id("synthetic-token")
        with self.assertRaises(ProviderUploadError):
            BillingPDFDriveUpload().generate_id("bad\r\ntoken")


if __name__ == "__main__":
    unittest.main()
