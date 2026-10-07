import hashlib
import io
import unittest
import urllib.request
import uuid
from unittest import mock

from Backend.billing_pdf_archive_ledger import BillingPDFKey, BillingPDFReservation
from Backend.billing_pdf_drive_readback import BillingPDFDriveReadback, ProviderReadbackError, transport


class BillingPDFDriveReadbackTests(unittest.TestCase):
    def setUp(self):
        self.bytes = b"%PDF-1.7\nfixture-customer-document"
        self.digest = hashlib.sha256(self.bytes).hexdigest()
        self.key = BillingPDFKey(str(uuid.uuid4()),
            "google-subject:" + hashlib.sha256(b"approved-google-subject").hexdigest(),
            "invoice", str(uuid.uuid4()), "a" * 64, "customer-pdf-v1")
        self.reservation = BillingPDFReservation(self.key, str(uuid.uuid4()),
            "2026-10-02T12:00:00+00:00", None, None, self.digest,
            "reserved-file-id", None)
        self.requests = []

    def send(self, request, *, media):
        self.requests.append((request.full_url, request.get_method(), media,
                              request.get_header("Authorization")))
        if media:
            return {"sha256": self.digest, "size": len(self.bytes)}
        return {
            "id": self.reservation.drive_file_id,
            "mimeType": "application/pdf", "trashed": False,
            "size": str(len(self.bytes)),
            "appProperties": {
                "gunnaireSchema": "2",
                "gunnaireAttachmentID": self.reservation.attachment_id,
                "gunnaireCompanyID": self.key.company_id,
                "gunnaireDocumentKind": self.key.document_kind,
                "gunnaireDocumentID": self.key.document_id,
                "gunnaireSourceDigest": self.key.source_digest,
                "gunnaireRendererVersion": self.key.renderer_version,
                "gunnaireContentSHA256": self.digest,
            },
        }

    def test_exact_metadata_and_bytes_yield_a_server_derived_link(self):
        result = BillingPDFDriveReadback(self.send).verify(self.key, self.reservation, "fixture-token")
        self.assertEqual(result, "https://drive.google.com/file/d/reserved-file-id/view")
        self.assertEqual([method for _, method, _, _ in self.requests], ["GET", "GET"])
        self.assertTrue(all(token == "Bearer fixture-token" for _, _, _, token in self.requests))
        self.assertEqual([media for _, _, media, _ in self.requests], [False, True])

    def test_wrong_revision_identity_or_bytes_cannot_confirm(self):
        for field, wrong in (("gunnaireDocumentID", str(uuid.uuid4())),
                             ("gunnaireSourceDigest", "b" * 64),
                             ("gunnaireRendererVersion", "other-renderer"),
                             ("gunnaireContentSHA256", "b" * 64)):
            def changed(request, *, media):
                result = self.send(request, media=media)
                if not media:
                    result["appProperties"][field] = wrong
                return result
            with self.subTest(field=field), self.assertRaises(ProviderReadbackError):
                BillingPDFDriveReadback(changed).verify(self.key, self.reservation, "fixture-token")
        def changed_bytes(request, *, media):
            result = self.send(request, media=media)
            return {"sha256": "b" * 64, "size": len(self.bytes)} if media else result
        with self.assertRaises(ProviderReadbackError):
            BillingPDFDriveReadback(changed_bytes).verify(self.key, self.reservation, "fixture-token")

    def test_missing_or_oversized_provider_file_fails_closed(self):
        def oversized(request, *, media):
            result = self.send(request, media=media)
            if not media:
                result["size"] = "100000001"
            return result
        with self.assertRaises(ProviderReadbackError):
            BillingPDFDriveReadback(oversized).verify(self.key, self.reservation, "fixture-token")
        for malformed_size in (None, -1, 3.5, "2.5", "00000000000000000001"):
            def malformed(request, *, media):
                result = self.send(request, media=media)
                if not media:
                    result["size"] = malformed_size
                return result
            with self.subTest(size=malformed_size), self.assertRaises(ProviderReadbackError):
                BillingPDFDriveReadback(malformed).verify(self.key, self.reservation, "fixture-token")
        def missing(request, *, media):
            raise ProviderReadbackError("Provider did not confirm file")
        with self.assertRaises(ProviderReadbackError):
            BillingPDFDriveReadback(missing).verify(self.key, self.reservation, "fixture-token")

    def test_fixed_origin_streaming_transport_never_follows_redirect_or_writes(self):
        class Response(io.BytesIO):
            status = 200
            def __enter__(self):
                return self
            def __exit__(self, *_):
                self.close()
        class Opener:
            def open(self, request, timeout):
                self.last = (request.get_method(), timeout)
                return Response(b"%PDF-1.7\nfixture-customer-document")
        opener = Opener()
        request = urllib.request.Request(
            "https://www.googleapis.com/drive/v3/files/reserved-file-id?alt=media",
            method="GET")
        with mock.patch("urllib.request.build_opener", return_value=opener) as builder:
            result = transport(request, media=True)
        self.assertEqual(result, {"sha256": self.digest, "size": len(self.bytes)})
        self.assertEqual(opener.last, ("GET", 30))
        self.assertEqual(builder.call_args.args[0].__name__, "NoRedirect")
        with self.assertRaises(ProviderReadbackError):
            transport(urllib.request.Request(
                "https://drive.google.com/drive/v3/files/reserved-file-id?alt=media",
                method="GET"), media=True)
        with self.assertRaises(ProviderReadbackError):
            transport(urllib.request.Request(
                "https://www.googleapis.com/drive/v3/files/reserved-file-id?alt=media",
                data=b"write", method="POST"), media=True)


if __name__ == "__main__":
    unittest.main()
