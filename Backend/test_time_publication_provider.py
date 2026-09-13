import copy
import io
import json
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid
from unittest import mock

from Backend import time_publication_provider as provider
from Backend.payment_attempts import AttemptError


class TimePublicationProviderTests(unittest.TestCase):
    def setUp(self):
        self.context = {"realm_id": "realm", "environment": "sandbox", "grant_fingerprint": "private-fixture"}
        self.identifier = str(uuid.uuid4())
        self.request_id = "ga-time-" + self.identifier
        self.document = {"TxnDate": "2026-08-01", "NameOf": "Employee", "EmployeeRef": {"value": "55"}, "Hours": 2, "Minutes": 1,
                         "Description": "Completed work\nGUNNAIRE-TIME:" + str(uuid.uuid4()).upper() + "\nGUNNAIRE-TIME-PUBLICATION:" + self.identifier.upper()}
        self.requests, self.events = [], []
        self.response = {"TimeActivity": {**self.document, "Id": "800", "SyncToken": "0"}}
        self.client = provider.TimeQBOProvider(self.context, lambda: self.events.append("authorize"), self.bearer, self.send)

    def bearer(self, context, actor):
        self.events.append("bearer")
        self.assertEqual(context, self.context)
        self.assertEqual(actor, "system:time-publication")
        return "fixture-token"

    def send(self, request):
        self.events.append("request")
        self.requests.append(request)
        return copy.deepcopy(self.response)

    def test_create_uses_exact_scoped_endpoint_original_payload_and_request_identity(self):
        result = self.client.create(self.document, self.request_id)
        self.assertEqual(result, self.response["TimeActivity"])
        request = self.requests[0]
        parsed = urllib.parse.urlsplit(request.full_url)
        self.assertEqual(parsed.hostname, "sandbox-quickbooks.api.intuit.com")
        self.assertEqual(parsed.path, "/v3/company/realm/timeactivity")
        self.assertEqual(urllib.parse.parse_qs(parsed.query), {"minorversion": ["75"], "requestid": [self.request_id]})
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(json.loads(request.data), self.document)
        self.assertEqual(self.events, ["authorize", "bearer", "authorize", "request", "authorize"])

    def test_read_whitelists_existing_references_and_never_changes_them(self):
        for kind in ("Employee", "Vendor", "Customer", "Item", "TimeActivity"):
            self.response = {kind: {"Id": "55", "Active": True}}
            self.assertEqual(self.client.read(kind, "55")["Id"], "55")
            self.assertEqual(self.requests[-1].get_method(), "GET")
            self.assertIsNone(self.requests[-1].data)
            self.assertIn("/" + kind.lower() + "/55?", self.requests[-1].full_url)

    def test_read_rejects_untrusted_resource_paths_before_bearer(self):
        for kind, reference in (("PayrollItem", "1"), ("Invoice", "1"), ("Employee", "../other"), ("Vendor", "55?delete=true")):
            with self.assertRaises(AttemptError):
                self.client.read(kind, reference)
        self.assertFalse(self.requests)
        self.assertFalse(self.events)

    def test_creation_rejects_update_delete_payroll_and_invalid_time_payloads(self):
        for changes in ({"Id": "existing"}, {"SyncToken": "0"}, {"operation": "delete"}, {"PayrollItemRef": {"value": "55"}},
                        {"ProjectRef": {"value": "55"}}, {"Hours": True}, {"Minutes": -1}, {"Hours": 8760}, {"Hours": -1},
                        {"Minutes": 60}, {"TxnDate": "2026-13-01"}, {"Description": "no identity"},
                        {"VendorRef": {"value": "55"}}, {"EmployeeRef": {"value": "55", "name": "device identity"}}):
            with self.assertRaises(AttemptError):
                self.client.create({**self.document, **changes}, self.request_id)
        for identifier in ("random", "ga-time-" + self.identifier.upper(), "ga-time-" + "a" * 36, self.request_id + "?delete=true"):
            with self.assertRaises(AttemptError):
                self.client.create(self.document, identifier)
        self.assertFalse(self.requests)

    def test_authorization_loss_after_refresh_prevents_create(self):
        authorize = mock.Mock(side_effect=[None, AttemptError("revoked", "fixture", 403)])
        send = mock.Mock()
        client = provider.TimeQBOProvider(self.context, authorize, self.bearer, send)
        with self.assertRaises(AttemptError):
            client.create(self.document, self.request_id)
        send.assert_not_called()

    def test_authorization_loss_after_send_does_not_return_stale_result_or_retry(self):
        authorize = mock.Mock(side_effect=[None, None, AttemptError("revoked", "fixture", 403)])
        client = provider.TimeQBOProvider(self.context, authorize, self.bearer, self.send)
        with self.assertRaises(AttemptError):
            client.create(self.document, self.request_id)
        self.assertEqual(len(self.requests), 1)

    def test_pagination_checks_all_pages_with_fixed_queries(self):
        pages = [{"QueryResponse": {"TimeActivity": [{"Id": str(n)} for n in range(100)], "startPosition": 1, "maxResults": 100}},
                 {"QueryResponse": {"TimeActivity": [{"Id": "last"}], "startPosition": 101, "maxResults": 1}}]
        def send(request):
            self.requests.append(request)
            return pages.pop(0)
        self.client.send = send
        self.assertEqual(len(self.client.activities()), 101)
        for index, request in enumerate(self.requests):
            self.assertEqual(request.get_method(), "GET")
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)
            self.assertEqual(query["query"], [f"SELECT * FROM TimeActivity ORDERBY TxnDate STARTPOSITION {1 + 100 * index} MAXRESULTS 100"])

    def test_empty_history_is_explicit_and_bounded(self):
        self.response = {"QueryResponse": {}}
        self.assertEqual(self.client.activities(), [])
        self.assertEqual(len(self.requests), 1)

    def test_incomplete_ambiguous_or_other_entity_pages_fail_closed(self):
        for response in ({}, {"Invoice": []}, {"TimeActivity": {}}, {"TimeActivity": [{"Id": "1"}]},
                         {"TimeActivity": [{"Id": "1"}], "maxResults": 2}, {"TimeActivity": [], "maxResults": True},
                         {"TimeActivity": [], "maxResults": 0, "startPosition": 101},
                         {"TimeActivity": [], "totalCount": 1}, {"TimeActivity": [], "totalCount": False},
                         {"TimeActivity": [None], "maxResults": 1}, {"TimeActivity": [{"Id": "../bad"}], "maxResults": 1}):
            self.response = {"QueryResponse": response} if response else {}
            with self.assertRaises(AttemptError):
                self.client.activities()

    def test_duplicate_identifiers_across_pages_reject_unstable_history(self):
        page = [{"Id": str(n)} for n in range(100)]
        self.client.send = mock.Mock(side_effect=[{"QueryResponse": {"TimeActivity": page, "maxResults": 100}},
            {"QueryResponse": {"TimeActivity": [{"Id": "0"}], "maxResults": 1, "startPosition": 101}}])
        with self.assertRaises(AttemptError):
            self.client.activities()

    def test_provider_history_limit_never_returns_partial_success(self):
        def send(request):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)["query"][0]
            start = int(provider.QUERY.fullmatch(query).group(1))
            return {"QueryResponse": {"TimeActivity": [{"Id": str(n)} for n in range(start, start + 100)], "maxResults": 100, "startPosition": start}}
        self.client.send = mock.Mock(side_effect=send)
        with self.assertRaises(AttemptError) as caught:
            self.client.activities()
        self.assertEqual(caught.exception.code, "time_history_review")
        self.assertEqual(self.client.send.call_count, 100)

    def test_fixed_transport_rejects_other_origins_routes_queries_methods_or_delete_body(self):
        root = "https://quickbooks.api.intuit.com/v3/company/realm/"
        valid = root + "timeactivity?minorversion=75&requestid=" + self.request_id
        body = json.dumps(self.document).encode()
        values = [(valid.replace("https:", "http:"), "POST", body), (valid.replace("quickbooks.api.intuit.com", "example.invalid"), "POST", body),
                  (valid.replace(".com/", ".com:444/"), "POST", body), (valid + "#fragment", "POST", body),
                  (valid.replace("https://", "https://user@"), "POST", body), (valid + "&operation=delete", "POST", body),
                  (valid + "&minorversion=75", "POST", body), (valid + "&requestid=" + self.request_id, "POST", body),
                  (valid.replace("timeactivity?", "employee?"), "POST", body), (valid, "DELETE", body),
                  (valid, "GET", body), (valid, "POST", b'{"Id":"1","SyncToken":"0"}'),
                  (root + "query?minorversion=75&query=SELECT+*+FROM+Employee", "GET", None),
                  (root + "query?minorversion=75&query=SELECT+*+FROM+TimeActivity&query=SELECT+*+FROM+Vendor", "GET", None)]
        with mock.patch.object(provider.urllib.request, "build_opener") as opener:
            for url, method, data in values:
                with self.assertRaises(AttemptError):
                    provider.transport(urllib.request.Request(url, data=data, method=method))
            opener.assert_not_called()

    def test_transport_strict_json_size_timeout_no_redirect_and_private_error_redaction(self):
        request = urllib.request.Request("https://quickbooks.api.intuit.com/v3/company/realm/timeactivity?minorversion=75&requestid=" + self.request_id,
                                        data=json.dumps(self.document).encode(), method="POST")
        response, opener = mock.MagicMock(), mock.MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        opener.open.return_value = response
        response.read.return_value = json.dumps(self.response).encode()
        with mock.patch.object(provider.urllib.request, "build_opener", return_value=opener) as factory:
            self.assertEqual(provider.transport(request), self.response)
            self.assertIsInstance(factory.call_args.args[0], provider.NoRedirect)
            self.assertEqual(opener.open.call_args.kwargs["timeout"], 20)
            self.assertEqual(response.read.call_args.args, (4 * 1024 * 1024 + 1,))
            for raw in (b"x" * (4 * 1024 * 1024 + 1), b"not json", b"[]", b'{"TimeActivity":{},"TimeActivity":{}}', b'{"x":NaN}', b'{"Fault":{"secret":"private"}}'):
                response.read.return_value = raw
                with self.assertRaises(AttemptError):
                    provider.transport(request)
            for error in (TimeoutError(), urllib.error.HTTPError(request.full_url, 500, "private salary", {}, io.BytesIO(b"private rate"))):
                opener.open.reset_mock()
                opener.open.side_effect = error
                with self.assertRaises(AttemptError) as caught:
                    provider.transport(request)
                self.assertNotIn("private", str(caught.exception))
                self.assertEqual(opener.open.call_count, 1)

    def test_wrong_resource_or_fault_response_does_not_confirm(self):
        for response in ({}, {"Fault": {}}, [], {"TimeActivity": []}):
            self.response = response
            with self.assertRaises(AttemptError):
                self.client.create(self.document, self.request_id)


if __name__ == "__main__":
    unittest.main()
