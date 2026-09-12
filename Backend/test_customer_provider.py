import io
import json
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid
from unittest import mock
from Backend import gunnaire_backend as backend
from Backend import customer_publications as customer


class CustomerProviderTests(unittest.TestCase):
    def setUp(self):
        self.context = {"realm_id": "fixture-realm", "environment": "sandbox", "grant_fingerprint": "fixture-grant"}
        self.check = mock.Mock()
        self.provider = backend.CustomerQBOProvider(self.context, self.check)
        self.bearer_patch = mock.patch.object(backend, "qbo_authorized_bearer", return_value="fixture-bearer")
        self.bearer = self.bearer_patch.start()
        self.identifier = str(uuid.uuid4())
        self.payload = {"DisplayName": "Taylor Customer", "Notes": customer.lineage(self.identifier)}
        self.request_id = "ga-customer-" + self.identifier

    def tearDown(self):
        self.bearer_patch.stop()

    def test_read_uses_original_fixed_origin_and_one_in_memory_bearer(self):
        with mock.patch.object(backend, "qbo_customer_transport", return_value={"Customer": {"Id": "C1"}}) as transport:
            self.provider.read("C1")
            self.provider.read("C2")
        self.assertEqual(self.bearer.call_count, 1)
        self.assertEqual(transport.call_args_list[0].args[0].full_url,
                         "https://sandbox-quickbooks.api.intuit.com/v3/company/fixture-realm/customer/C1?minorversion=75")
        self.assertEqual(transport.call_args.args[0].get_method(), "GET")

    def test_invalid_resource_reference_or_environment_never_accesses_credentials(self):
        with mock.patch.object(backend, "qbo_customer_transport") as transport:
            for identifier in ("../other", "https://example.invalid", "x?foo=bar", ""):
                with self.assertRaises(customer.AttemptError):
                    self.provider.read(identifier)
            with self.assertRaises(customer.AttemptError):
                self.provider.request("invoice")
            self.context["environment"] = "unknown"
            with self.assertRaises(customer.AttemptError):
                self.provider.read("C1")
            transport.assert_not_called()
        self.bearer.assert_not_called()

    def test_claim_immediately_precedes_post_after_refresh(self):
        events = []
        self.check.side_effect = lambda: events.append("authorize")
        self.bearer.side_effect = lambda *args: events.append("refresh") or "fixture-bearer"
        def send(request):
            events.append("send")
            self.assertEqual(events[-2], "claim")
            self.assertEqual(request.get_method(), "POST")
            self.assertEqual(json.loads(request.data), self.payload)
            self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)["requestid"], [self.request_id])
            return {"Customer": {"Id": "C1"}}
        with mock.patch.object(backend, "qbo_customer_transport", side_effect=send):
            self.provider.write(self.payload, self.request_id, lambda: events.append("claim"))
        self.assertLess(events.index("refresh"), events.index("claim"))

    def test_refresh_failure_never_consumes_dispatch(self):
        self.bearer.side_effect = customer.failure("unavailable", "Fixture unavailable.")
        claim = mock.Mock()
        with mock.patch.object(backend, "qbo_customer_transport") as transport, self.assertRaises(customer.AttemptError):
            self.provider.write(self.payload, self.request_id, claim)
        claim.assert_not_called()
        transport.assert_not_called()

    def test_denied_claim_prevents_post(self):
        claim = mock.Mock(side_effect=customer.failure("already_sent", "Fixture already sent."))
        with mock.patch.object(backend, "qbo_customer_transport") as transport, self.assertRaises(customer.AttemptError):
            self.provider.write(self.payload, self.request_id, claim)
        transport.assert_not_called()

    def test_access_revoked_after_provider_response_cannot_return_confirmation(self):
        def send(request):
            self.check.side_effect = customer.failure("revoked", "Fixture revoked.")
            return {"Customer": {"Id": "C1"}}
        with mock.patch.object(backend, "qbo_customer_transport", side_effect=send), self.assertRaises(customer.AttemptError):
            self.provider.write(self.payload, self.request_id, lambda: None)

    def test_write_rejects_foreign_lineage_update_and_opening_balance(self):
        with mock.patch.object(backend, "qbo_customer_transport") as transport:
            for change in ({"Notes": "forged"}, {"Balance": 100}, {"Id": "C1"}, {"SyncToken": "0"}, {"sparse": True}):
                with self.assertRaises(customer.AttemptError):
                    self.provider.write({**self.payload, **change}, self.request_id, lambda: None)
            with self.assertRaises(customer.AttemptError):
                self.provider.write(self.payload, "other-request", lambda: None)
            transport.assert_not_called()

    def test_customer_census_includes_inactive_and_more_than_one_page(self):
        values = [{"Id": str(index)} for index in range(1001)]
        def send(request):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)["query"][0]
            self.assertIn("Active IN (true, false)", query)
            if "COUNT(*)" in query:
                return {"QueryResponse": {"totalCount": 1001}}
            self.assertIn("ORDERBY DisplayName", query)
            start = 1 if "STARTPOSITION 1 " in query else 1001
            page = values[start - 1:start + 999]
            return {"QueryResponse": {"Customer": page, "startPosition": start, "maxResults": len(page)}}
        with mock.patch.object(backend, "qbo_customer_transport", side_effect=send) as transport:
            self.assertEqual(self.provider.customers(), values)
            self.assertEqual(transport.call_count, 4)

    def test_missing_nonfinite_bool_or_excessive_counts_do_not_mean_empty(self):
        for value in (None, True, -1, 100001, float("nan")):
            with mock.patch.object(backend, "qbo_customer_transport", return_value={"QueryResponse": {"totalCount": value}}), self.assertRaises(customer.AttemptError):
                self.provider.customers()

    def test_empty_census_needs_matching_end_count(self):
        with mock.patch.object(backend, "qbo_customer_transport", return_value={"QueryResponse": {"totalCount": 0}}) as transport:
            self.assertEqual(self.provider.customers(), [])
            self.assertEqual(transport.call_count, 2)
        with mock.patch.object(backend, "qbo_customer_transport", side_effect=[{"QueryResponse": {"totalCount": 0}},
             {"QueryResponse": {"totalCount": 1}}]), self.assertRaises(customer.AttemptError):
            self.provider.customers()

    def test_partial_repeated_or_misaligned_pages_stop_comparison(self):
        for page in ({"Customer": []}, {"Customer": [{"Id": "1"}, {"Id": "1"}]},
                     {"Customer": [{"Id": "1"}, {"Id": "2"}], "startPosition": 2},
                     {"Customer": [{"Id": "1"}, {"Id": "2"}], "maxResults": 999}):
            with mock.patch.object(backend, "qbo_customer_transport", side_effect=[{"QueryResponse": {"totalCount": 2}},
                 {"QueryResponse": page}]), self.assertRaises(customer.AttemptError):
                self.provider.customers()

    def test_transport_rejects_other_hosts_methods_and_resources_without_network(self):
        invalid = (("https://example.invalid/v3/company/realm/customer", "POST"),
                   ("http://quickbooks.api.intuit.com/v3/company/realm/customer", "POST"),
                   ("https://user@quickbooks.api.intuit.com/v3/company/realm/customer", "POST"),
                   ("https://quickbooks.api.intuit.com:444/v3/company/realm/customer", "POST"),
                   ("https://quickbooks.api.intuit.com/v3/company/realm/invoice", "POST"),
                   ("https://quickbooks.api.intuit.com/v3/company/realm/query", "POST"),
                   ("https://quickbooks.api.intuit.com/v3/company/realm/customer/C1", "DELETE"),
                   ("https://quickbooks.api.intuit.com/v3/company/realm/customer#other", "POST"))
        with mock.patch.object(backend.urllib.request, "build_opener") as opener:
            for url, method in invalid:
                with self.assertRaises(customer.AttemptError):
                    backend.qbo_customer_transport(urllib.request.Request(url, method=method))
            opener.assert_not_called()

    def test_transport_is_bounded_no_redirect_and_does_not_expose_provider_errors(self):
        request = urllib.request.Request("https://quickbooks.api.intuit.com/v3/company/realm/customer", method="POST")
        opener = mock.MagicMock()
        opener.open.side_effect = urllib.error.HTTPError(request.full_url, 400, "fixture secret", {}, io.BytesIO(b"private provider data"))
        with mock.patch.object(backend.urllib.request, "build_opener", return_value=opener) as factory:
            with self.assertRaises(customer.AttemptError) as caught:
                backend.qbo_customer_transport(request)
            self.assertNotIn("private", str(caught.exception))
            self.assertNotIn("secret", str(caught.exception))
            self.assertIsInstance(factory.call_args.args[0], backend.QBOReadNoRedirect)
        for body in (b"not json", b"[]", b"x" * (1024 * 1024 + 1)):
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.status, response.read.return_value = 200, body
            opener.open.side_effect, opener.open.return_value = None, response
            with mock.patch.object(backend.urllib.request, "build_opener", return_value=opener), self.assertRaises(customer.AttemptError):
                backend.qbo_customer_transport(request)
            response.read.assert_called_once_with(1024 * 1024 + 1)
            self.assertEqual(opener.open.call_args.kwargs["timeout"], 20)


if __name__ == "__main__":
    unittest.main()
