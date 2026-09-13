import io
import json
import unittest
import urllib.error
import urllib.request
from unittest import mock

from Backend import time_worker_provider as provider
from Backend.time_worker_mappings import AttemptError, worker_reference


class TimeWorkerProviderTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.context = {"realm_id": "realm", "environment": "sandbox", "grant_fingerprint": "fixture-grant"}
        self.value = {"Id": "55", "SyncToken": "0", "Active": True, "DisplayName": "Fixture Technician"}
        self.client = provider.TimeWorkerQBOProvider(self.context, lambda: self.events.append("authorize"), self.bearer, self.send)

    def bearer(self, context, actor):
        self.events.append("bearer")
        self.assertEqual(context, self.context)
        self.assertEqual(actor, "system:time-worker-review")
        return "fixture-token"

    def send(self, request):
        self.events.append("read")
        self.assertEqual(request.get_method(), "GET")
        self.assertIsNone(request.data)
        self.assertEqual(request.headers["Authorization"], "Bearer fixture-token")
        self.assertEqual(request.full_url, "https://sandbox-quickbooks.api.intuit.com/v3/company/realm/employee/55?minorversion=75")
        return {"Employee": self.value}

    def test_scoped_read_reauthorizes_before_and_after_token_refresh_and_response(self):
        self.assertEqual(self.client.read("Employee", "55"), self.value)
        self.assertEqual(self.events, ["authorize", "bearer", "authorize", "read", "authorize"])

    def test_production_vendor_uses_exact_production_origin(self):
        client = provider.TimeWorkerQBOProvider({**self.context, "environment": "production"}, lambda: None,
            lambda *_: "fixture-token", lambda req: {"Vendor": {**self.value, "url": req.full_url}})
        result = client.read("Vendor", "55")
        self.assertEqual(result["url"], "https://quickbooks.api.intuit.com/v3/company/realm/vendor/55?minorversion=75")

    def test_no_arbitrary_resource_or_path_reaches_bearer_loader(self):
        for kind, identifier in (("Invoice", "55"), ("employee", "55"), ("Employee", ".."),
                                 ("Vendor", "../employee/1"), ("Employee", "55?operation=delete"), ("Vendor", "")):
            with self.assertRaises(AttemptError):
                self.client.read(kind, identifier)
        self.assertFalse(self.events)

    def test_invalid_context_rejected_before_any_connection(self):
        for change in ({"realm_id": "../other"}, {"environment": "other"}):
            with self.assertRaises(AttemptError):
                provider.TimeWorkerQBOProvider({**self.context, **change}, lambda: None, self.bearer)
        self.assertFalse(self.events)

    def test_access_loss_before_read_stops_the_network(self):
        authorize = mock.Mock(side_effect=[None, AttemptError("revoked", "fixture", 403)])
        send = mock.Mock()
        client = provider.TimeWorkerQBOProvider(self.context, authorize, self.bearer, send)
        with self.assertRaises(AttemptError):
            client.read("Employee", "55")
        send.assert_not_called()

    def test_access_loss_after_read_does_not_return_private_result(self):
        authorize = mock.Mock(side_effect=[None, None, AttemptError("revoked", "fixture", 403)])
        client = provider.TimeWorkerQBOProvider(self.context, authorize, self.bearer, lambda _: {"Employee": self.value})
        with self.assertRaises(AttemptError):
            client.read("Employee", "55")

    def test_malformed_or_different_worker_is_not_accepted(self):
        for result in ({}, [], {"Employee": {}}, {"Employee": {"Id": "other"}}, {"Vendor": self.value}):
            client = provider.TimeWorkerQBOProvider(self.context, lambda: None, self.bearer, lambda _, result=result: result)
            with self.assertRaises(AttemptError):
                client.read("Employee", "55")

    def test_transport_rejects_writes_arbitrary_origins_queries_and_resources(self):
        valid = "https://quickbooks.api.intuit.com/v3/company/realm/employee/55?minorversion=75"
        bad = ((valid, "POST", b"{}"), (valid, "DELETE", None), (valid, "GET", b"{}"),
               (valid.replace("https:", "http:"), "GET", None), (valid.replace(".com/", ".com:444/"), "GET", None),
               (valid.replace("quickbooks.api.intuit.com", "example.invalid"), "GET", None),
               (valid.replace("employee/55", "invoice/55"), "GET", None), (valid + "&operation=delete", "GET", None),
               (valid + "&minorversion=75", "GET", None), (valid + "#fragment", "GET", None),
               (valid.replace("https://", "https://user@"), "GET", None), (valid.replace("75", "74"), "GET", None))
        with mock.patch.object(provider.urllib.request, "build_opener") as opener:
            for url, method, body in bad:
                with self.assertRaises(AttemptError):
                    provider.transport(urllib.request.Request(url, data=body, method=method))
            opener.assert_not_called()

    def test_transport_bounded_strict_json_and_nonredirecting_success(self):
        request = urllib.request.Request("https://quickbooks.api.intuit.com/v3/company/realm/employee/55?minorversion=75")
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = json.dumps({"Employee": self.value}).encode()
        opener = mock.MagicMock()
        opener.open.return_value = response
        with mock.patch.object(provider.urllib.request, "build_opener", return_value=opener) as factory:
            self.assertEqual(provider.transport(request), {"Employee": self.value})
            self.assertIsInstance(factory.call_args.args[0], provider.NoRedirect)
        response.read.assert_called_once_with(1024 * 1024 + 1)
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 20)
        self.assertIsNone(provider.NoRedirect().redirect_request(None, None, 302, "move", {}, "https://example.invalid"))

    def test_transport_rejects_oversized_malformed_and_duplicate_provider_json(self):
        request = urllib.request.Request("https://quickbooks.api.intuit.com/v3/company/realm/vendor/55?minorversion=75")
        for body in (b"x" * (1024 * 1024 + 1), b"not json", b"[]", b'{"Vendor":{},"Vendor":{}}', b'{"value":NaN}'):
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.status = 200
            response.read.return_value = body
            opener = mock.MagicMock()
            opener.open.return_value = response
            with mock.patch.object(provider.urllib.request, "build_opener", return_value=opener), self.assertRaises(AttemptError):
                provider.transport(request)

    def test_transport_does_not_expose_raw_provider_error_or_retry(self):
        request = urllib.request.Request("https://quickbooks.api.intuit.com/v3/company/realm/employee/55?minorversion=75")
        for error in (urllib.error.HTTPError(request.full_url, 403, "secret worker", {}, io.BytesIO(b"private salary")), TimeoutError()):
            opener = mock.MagicMock()
            opener.open.side_effect = error
            with mock.patch.object(provider.urllib.request, "build_opener", return_value=opener), self.assertRaises(AttemptError) as caught:
                provider.transport(request)
            self.assertNotIn("salary", str(caught.exception))
            self.assertNotIn("secret", str(caught.exception))
            self.assertEqual(opener.open.call_count, 1)

    def test_same_id_renamed_worker_changes_visible_review_fingerprint(self):
        first = worker_reference(self.value, "Employee", "55")
        second = worker_reference({**self.value, "DisplayName": "Changed Name"}, "Employee", "55")
        self.assertNotEqual(first["referenceRevision"], second["referenceRevision"])
