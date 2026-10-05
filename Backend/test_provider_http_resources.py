"""Provider failures release response handles without reading private bodies."""
import io
import unittest
import urllib.error
import urllib.request
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import billing_provider, billing_pdf_drive_readback
from Backend import qbo_change_capture, qbo_document_provider
from Backend import time_worker_provider, time_publication_provider, transactional_email
from Backend.payment_attempts import AttemptError


class PrivateBody(io.BytesIO):
    def read(self, *args, **kwargs):
        raise AssertionError("Provider error bodies must not be read")


class ProviderHTTPResourceTests(unittest.TestCase):
    def error(self, url, code):
        body = PrivateBody(b"private fixture provider details")
        error = urllib.error.HTTPError(url, code, "private fixture message", {}, body)
        self.addCleanup(error.close)
        return error, body

    def test_provider_reads_close_rejected_responses_without_retry(self):
        base = "https://quickbooks.api.intuit.com/v3/company/realm/"
        cases = [
            ("payment", backend.qbo_payment_read_transport, base + "invoice/I1?minorversion=75", AttemptError),
            ("catalog", backend.qbo_catalog_transport, base + "item/I1?minorversion=75", AttemptError),
            ("customer", backend.qbo_customer_transport, base + "customer/C1?minorversion=75", AttemptError),
            ("billing", billing_provider.transport, base + "invoice/I1?minorversion=75", AttemptError),
            ("worker", time_worker_provider.transport, base + "employee/E1?minorversion=75", AttemptError),
            ("time", time_publication_provider.transport, base + "timeactivity/T1?minorversion=75", AttemptError),
            ("document", qbo_document_provider.transport, base + "invoice/I1?minorversion=75", AttemptError),
            ("capture", qbo_change_capture.transport,
             base + "cdc?minorversion=75&entities=Item&changedSince=2026-09-08T00:00:00Z", AttemptError),
            ("drive metadata", lambda request: billing_pdf_drive_readback.transport(request, media=False),
             "https://www.googleapis.com/drive/v3/files/fixture?fields=id,mimeType,trashed,appProperties,size",
             billing_pdf_drive_readback.ProviderReadbackError),
            ("drive media", lambda request: billing_pdf_drive_readback.transport(request, media=True),
             "https://www.googleapis.com/drive/v3/files/fixture?alt=media",
             billing_pdf_drive_readback.ProviderReadbackError),
        ]
        for name, send, url, expected_error in cases:
            for status in (401, 429):
                with self.subTest(provider=name, status=status):
                    error, body = self.error(url, status)
                    with mock.patch.object(urllib.request, "build_opener") as opener:
                        opener.return_value.open.side_effect = error
                        with self.assertRaises(expected_error) as caught:
                            send(urllib.request.Request(url))
                        opener.return_value.open.assert_called_once()
                    if isinstance(caught.exception, AttemptError):
                        expected_code = {"worker": "worker_unavailable", "time": "time_provider_unavailable"}.get(name, "provider_unavailable")
                        if name == "capture" and status == 429:
                            expected_code = "provider_throttled"
                        self.assertEqual(caught.exception.code, expected_code)
                    self.assertNotIn("private fixture", str(caught.exception))
                    self.assertTrue(body.closed, name)

    def test_oauth_keeps_status_and_sanitization_while_closing_response(self):
        url = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer"
        for status in (400, 401, 429, 500):
            with self.subTest(status=status):
                error, body = self.error(url, status)
                with mock.patch.object(backend, "qbo_is_configured", return_value=True), \
                        mock.patch.object(urllib.request, "urlopen", side_effect=error) as opened:
                    code, payload = backend.qbo_request({"grant_type": "fixture"}, url)
                self.assertEqual(code, status)
                self.assertEqual(payload, {"error": "QuickBooks rejected the OAuth request", "status": status})
                opened.assert_called_once()
                self.assertTrue(body.closed)

    def test_apple_key_failure_closes_response_and_keeps_failure(self):
        error, body = self.error(backend.APPLE_JWKS_URL, 503)
        with mock.patch.object(urllib.request, "urlopen", side_effect=error) as opened:
            with self.assertRaisesRegex(ValueError, "Apple signing keys are unavailable"):
                backend.apple_public_key("fixture-key", force_refresh=True)
        opened.assert_called_once()
        self.assertTrue(body.closed)

    def test_transactional_email_failure_closes_response_without_resending(self):
        error, body = self.error(transactional_email.POSTMARK_ENDPOINT, 503)
        opened = mock.Mock(side_effect=error)
        self.assertFalse(transactional_email.send_transactional_email(
            api_key="fixture", from_address="sender@example.com", to_address="recipient@example.com",
            subject="Fixture", text_body="Fixture", opener=opened))
        opened.assert_called_once()
        self.assertTrue(body.closed)

    def test_injected_document_transport_error_is_closed(self):
        url = "https://quickbooks.api.intuit.com/v3/company/realm/invoice/I1?minorversion=75"
        error, body = self.error(url, 429)
        send = mock.Mock(side_effect=error)
        provider = qbo_document_provider.DocumentQBOProvider(
            {"realm_id": "realm", "environment": "production"}, mock.Mock(),
            mock.Mock(return_value="fixture-only-token"), send=send)
        with self.assertRaises(AttemptError) as caught:
            provider.request("invoice/I1")
        self.assertEqual(caught.exception.code, "provider_unavailable")
        send.assert_called_once()
        self.assertTrue(body.closed)
