from __future__ import annotations

import hashlib
import io
import json
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import payment_attempts


class PaymentProviderReadTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.settings = mock.patch.multiple(backend, DATA_ROOT=root, DB_PATH=root / "test.sqlite3",
            STORAGE_ROOT=root / "files", QBO_ENVIRONMENT="sandbox", QBO_CLIENT_ID="fixture-client",
            PRIMARY_ADMIN_EMAIL="owner@example.invalid")
        self.settings.start()
        backend.initialize_database()
        with backend.db() as connection:
            connection.execute("INSERT INTO qbo_connections VALUES (1,?,?,?,?,?,?)",
                ("fixture-realm", "fixture-ciphertext", "sandbox",
                 hashlib.sha256(b"fixture-client").hexdigest(), "fixture-grant", "fixture-updated"))
            row = dict(connection.execute("SELECT * FROM qbo_connections").fetchone())
        self.context = {**row, "grant_fingerprint": payment_attempts.grant_fingerprint(row)}
        self.decrypt = mock.patch.object(backend, "decrypt_qbo_refresh_token", return_value="fixture-refresh")
        self.encrypt = mock.patch.object(backend, "encrypt_qbo_refresh_token", return_value="fixture-rotated-ciphertext")
        self.oauth = mock.patch.object(backend, "qbo_request", return_value=(200, {
            "access_token": "fixture-access", "refresh_token": "fixture-refresh-rotated", "expires_in": 3600}))
        self.decrypt.start()
        self.encrypt.start()
        self.oauth_mock = self.oauth.start()

    def tearDown(self):
        self.oauth.stop()
        self.encrypt.stop()
        self.decrypt.stop()
        self.settings.stop()
        self.directory.cleanup()

    def test_reads_fixed_invoice_accounting_card_ach_and_refund_resources(self):
        cases = [
            ("invoice", {}, "/v3/company/fixture-realm/invoice/fixture-record", "Invoice"),
            ("accounting", {}, "/v3/company/fixture-realm/payment/fixture-record", "Payment"),
            ("accounting", {"kind": "refund"}, "/v3/company/fixture-realm/refundreceipt/fixture-record", "RefundReceipt"),
            ("transaction", {}, "/quickbooks/v4/payments/charges/fixture-record", None),
            ("transaction", {"rail": "ach"}, "/quickbooks/v4/payments/echecks/fixture-record", None),
            ("transaction", {"kind": "refund", "source_id": "fixture-source"},
             "/quickbooks/v4/payments/charges/fixture-source/refunds/fixture-record", None),
            ("transaction", {"kind": "refund", "rail": "ach", "source_id": "fixture-source"},
             "/quickbooks/v4/payments/echecks/fixture-source/refunds/fixture-record", None),
        ]
        for category, options, path, envelope in cases:
            with self.subTest(category=category, options=options):
                value = {"Id": "fixture-record"} if envelope else {"id": "fixture-record"}
                payload = {envelope: value} if envelope else value
                with mock.patch.object(backend, "qbo_payment_read_transport", return_value=(200, payload)) as transport:
                    result = backend.read_payment_provider_record(self.context, category, "fixture-record", **options)
                request = transport.call_args.args[0]
                parsed = urllib.parse.urlsplit(request.full_url)
                self.assertEqual(request.get_method(), "GET")
                self.assertEqual(parsed.path, path)
                self.assertEqual(parsed.hostname, "sandbox-quickbooks.api.intuit.com" if envelope else "sandbox.api.intuit.com")
                self.assertEqual(request.get_header("Authorization"), "Bearer fixture-access")
                self.assertEqual(result, value)
                self.assertNotIn("fixture-access", str(result))
        with backend.db() as connection:
            count = connection.execute("SELECT COUNT(*) FROM audit_events WHERE action='refresh'").fetchone()[0]
        self.assertEqual(count, len(cases))

    def test_invalid_resources_and_original_environment_are_rejected_before_refresh(self):
        cases = [
            (self.context, "transaction", "../other", {}),
            (self.context, "transaction", "fixture", {"kind": "refund", "source_id": "../source"}),
            (self.context, "unknown", "fixture", {}),
            ({**self.context, "environment": "production"}, "invoice", "fixture", {}),
            ({**self.context, "realm_id": "another-realm"}, "invoice", "fixture", {}),
        ]
        with mock.patch.object(backend, "qbo_payment_read_transport") as transport:
            for context, category, ref, kwargs in cases:
                with self.assertRaises(payment_attempts.AttemptError):
                    backend.read_payment_provider_record(context, category, ref, **kwargs)
            transport.assert_not_called()
        self.oauth_mock.assert_not_called()

    def test_replaced_grant_during_refresh_never_sends_a_provider_get(self):
        def refresh(*args):
            with backend.db() as connection:
                connection.execute("UPDATE qbo_connections SET authorized_at='replacement',refresh_token_ciphertext='replacement-cipher'")
            return 200, {"access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3600}
        self.oauth_mock.side_effect = refresh
        with mock.patch.object(backend, "qbo_payment_read_transport") as transport:
            with self.assertRaises(payment_attempts.AttemptError):
                backend.read_payment_provider_record(self.context, "invoice", "fixture")
            transport.assert_not_called()
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT refresh_token_ciphertext FROM qbo_connections").fetchone()[0], "replacement-cipher")

    def test_replaced_grant_during_provider_get_discards_the_result(self):
        def read(request):
            with backend.db() as connection:
                connection.execute("UPDATE qbo_connections SET authorized_at='replacement'")
            return 200, {"Invoice": {"Id": "fixture"}}
        with mock.patch.object(backend, "qbo_payment_read_transport", side_effect=read):
            with self.assertRaises(payment_attempts.AttemptError):
                backend.read_payment_provider_record(self.context, "invoice", "fixture")

    def test_refresh_and_audit_commit_together(self):
        with mock.patch.object(backend, "record_audit_event", side_effect=RuntimeError("fixture audit failure")):
            with mock.patch.object(backend, "qbo_payment_read_transport") as transport:
                with self.assertRaises(RuntimeError):
                    backend.read_payment_provider_record(self.context, "invoice", "fixture")
                transport.assert_not_called()
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT refresh_token_ciphertext FROM qbo_connections").fetchone()[0], "fixture-ciphertext")

    def test_missing_envelope_and_failed_http_do_not_become_evidence(self):
        for status, payload in [(200, {}), (200, {"Invoice": []}), (500, {"private": "fixture-sensitive"})]:
            with mock.patch.object(backend, "qbo_payment_read_transport", return_value=(status, payload)):
                with self.assertRaises(payment_attempts.AttemptError) as failure:
                    backend.read_payment_provider_record(self.context, "invoice", "fixture")
                self.assertNotIn("fixture-sensitive", str(failure.exception))

    def test_transport_blocks_non_get_non_intuit_and_redirects(self):
        for method, url in [("POST", "https://api.intuit.com"), ("GET", "https://example.invalid"),
                            ("GET", "http://api.intuit.com"), ("GET", "https://api.intuit.com:444"),
                            ("GET", "https://user@api.intuit.com"), ("GET", "https://api.intuit.com#fragment")]:
            with mock.patch.object(urllib.request, "build_opener") as opener:
                with self.assertRaises(payment_attempts.AttemptError):
                    backend.qbo_payment_read_transport(urllib.request.Request(url, method=method))
                opener.assert_not_called()
        request = urllib.request.Request("https://api.intuit.com", headers={"Authorization": "fixture-private"})
        self.assertIsNone(backend.QBOReadNoRedirect().redirect_request(request, None, 302, "redirect", {}, "https://example.invalid"))

    def test_transport_bounds_and_sanitizes_all_unverifiable_bodies(self):
        request = urllib.request.Request("https://api.intuit.com", method="GET")
        for raw in [b"fixture-sensitive", b"[]", b"\xff", b"x" * (1024 * 1024 + 1)]:
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.read.return_value = raw
            response.status = 200
            opener = mock.Mock()
            opener.open.return_value = response
            with mock.patch.object(urllib.request, "build_opener", return_value=opener):
                with self.assertRaises(payment_attempts.AttemptError) as failure:
                    backend.qbo_payment_read_transport(request)
            self.assertNotIn("fixture-sensitive", str(failure.exception))
            response.read.assert_called_once_with(1024 * 1024 + 1)
        for error in [urllib.error.URLError("fixture-sensitive"),
                      urllib.error.HTTPError(request.full_url, 403, "fixture-sensitive", {}, io.BytesIO(b"fixture-sensitive")),
                      TimeoutError("fixture-sensitive")]:
            opener = mock.Mock()
            opener.open.side_effect = error
            with mock.patch.object(urllib.request, "build_opener", return_value=opener):
                with self.assertRaises(payment_attempts.AttemptError) as failure:
                    backend.qbo_payment_read_transport(request)
            self.assertNotIn("fixture-sensitive", str(failure.exception))


if __name__ == "__main__":
    unittest.main()
