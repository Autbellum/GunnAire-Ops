from __future__ import annotations
import io
import json
import unittest
import urllib.error
import urllib.parse
import urllib.request
from unittest import mock
from Backend import gunnaire_backend as backend
from Backend import catalog_publications as catalog


class CatalogProviderTests(unittest.TestCase):
    def setUp(self):
        self.context = {"realm_id": "fixture-realm", "environment": "sandbox", "grant_fingerprint": "fixture-grant"}
        self.check = mock.Mock()
        self.provider = backend.CatalogQBOProvider(self.context, self.check)
        self.bearer = mock.patch.object(backend, "qbo_authorized_bearer", return_value="fixture-bearer")
        self.refresh = self.bearer.start()
        self.requests = []

    def tearDown(self):
        self.bearer.stop()

    def transport(self, payload):
        def send(request):
            self.requests.append(request)
            return payload
        return mock.patch.object(backend, "qbo_catalog_transport", side_effect=send)

    def test_item_and_vendor_reads_use_only_original_fixed_accounting_origin(self):
        for entity in ("item", "vendor"):
            with self.transport({entity.title(): {"Id": "fixture-id"}}):
                self.provider.read(entity, "fixture-id")
            request = self.requests[-1]
            self.assertEqual(request.full_url, "https://sandbox-quickbooks.api.intuit.com/v3/company/fixture-realm/" + entity + "/fixture-id?minorversion=75")
            self.assertEqual(request.get_method(), "GET")
            self.assertEqual(request.get_header("Authorization"), "Bearer fixture-bearer")
        self.assertEqual(self.refresh.call_count, 1)

    def test_bad_read_resource_or_reference_cannot_reach_transport(self):
        with self.transport({}):
            for entity, identifier in (("invoice", "I1"), ("item", "../other"), ("vendor", "https://example.invalid")):
                with self.assertRaises(catalog.AttemptError):
                    self.provider.read(entity, identifier)
        self.assertFalse(self.requests)

    def test_write_claim_occurs_after_refresh_and_immediately_before_transport(self):
        events = []
        self.check.side_effect = lambda: events.append("authorize")
        self.refresh.side_effect = lambda *args: events.append("refresh") or "fixture-bearer"
        def send(request):
            events.append("send")
            self.assertEqual(events[-2], "claim")
            self.requests.append(request)
            return {"Item": {"Id": "I1"}}
        with mock.patch.object(backend, "qbo_catalog_transport", side_effect=send):
            self.provider.write({"Name": "Service"}, "ga-item-fixture", lambda: events.append("claim"))
        self.assertLess(events.index("refresh"), events.index("claim"))
        self.assertEqual(self.requests[0].get_method(), "POST")
        self.assertEqual(json.loads(self.requests[0].data), {"Name": "Service"})
        self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlsplit(self.requests[0].full_url).query)["requestid"], ["ga-item-fixture"])

    def test_refresh_failure_does_not_claim_or_send(self):
        self.refresh.side_effect = catalog.failure("connection_unavailable", "Fixture unavailable.", 503)
        claim = mock.Mock()
        with self.transport({}), self.assertRaises(catalog.AttemptError):
            self.provider.write({"Name": "Service"}, "ga-item-fixture", claim)
        claim.assert_not_called()
        self.assertFalse(self.requests)

    def test_revocation_after_refresh_prevents_claim(self):
        def refresh(*args):
            self.check.side_effect = catalog.failure("administrator_required", "Fixture revoked.", 403)
            return "fixture-bearer"
        self.refresh.side_effect = refresh
        claim = mock.Mock()
        with self.transport({}), self.assertRaises(catalog.AttemptError):
            self.provider.write({"Name": "Service"}, "ga-item-fixture", claim)
        claim.assert_not_called()
        self.assertFalse(self.requests)

    def test_rejected_claim_does_not_send(self):
        with self.transport({}), self.assertRaises(catalog.AttemptError):
            self.provider.write({"Name": "Service"}, "ga-item-fixture",
                                mock.Mock(side_effect=catalog.failure("publication_pending", "Fixture already claimed.")))
        self.assertFalse(self.requests)

    def test_access_loss_after_response_is_not_returned_as_confirmed(self):
        def send(request):
            self.check.side_effect = catalog.failure("administrator_required", "Fixture revoked.", 403)
            return {"Item": {"Id": "I1"}}
        with mock.patch.object(backend, "qbo_catalog_transport", side_effect=send), self.assertRaises(catalog.AttemptError):
            self.provider.write({"Name": "Service"}, "ga-item-fixture", lambda: None)

    def test_catalog_enumerates_inactive_items_with_verified_counts_and_pages(self):
        items = [{"Id": str(index), "Name": "Service " + str(index), "Active": False} for index in range(1001)]
        def send(request):
            self.requests.append(request)
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)["query"][0]
            self.assertIn("Active IN (true, false)", query)
            if "COUNT(*)" in query:
                return {"QueryResponse": {"totalCount": 1001}}
            start = 1 if "STARTPOSITION 1 " in query else 1001
            page = items[start-1:start+999]
            return {"QueryResponse": {"Item": page, "startPosition": start, "maxResults": len(page)}}
        with mock.patch.object(backend, "qbo_catalog_transport", side_effect=send):
            self.assertEqual(len(self.provider.items()), 1001)
        self.assertEqual(len(self.requests), 4)

    def test_empty_catalog_requires_two_successful_counts(self):
        with self.transport({"QueryResponse": {"totalCount": 0}}):
            self.assertEqual(self.provider.items(), [])
        self.assertEqual(len(self.requests), 2)

    def test_malformed_counts_do_not_imply_an_empty_catalog(self):
        for payload in ({}, {"QueryResponse": {}}, {"QueryResponse": {"totalCount": True}},
                        {"QueryResponse": {"totalCount": -1}}, {"QueryResponse": {"totalCount": 100001}}):
            with self.transport(payload), self.assertRaises(catalog.AttemptError):
                self.provider.items()

    def test_partial_or_repeated_pages_prevent_publication(self):
        bad_pages = ({"Item": []}, {"Item": [{"Id": "1"}, {"Id": "1"}]},
                     {"Item": [{"Id": "1"}, {"Id": "2"}], "startPosition": 2},
                     {"Item": [{"Id": "1"}, {"Id": "2"}], "maxResults": 999})
        for page in bad_pages:
            with mock.patch.object(backend, "qbo_catalog_transport",
                side_effect=[{"QueryResponse": {"totalCount": 2}}, {"QueryResponse": page}]), self.assertRaises(catalog.AttemptError):
                self.provider.items()

    def test_changed_final_count_rejects_nontransactional_snapshot(self):
        with mock.patch.object(backend, "qbo_catalog_transport", side_effect=[
            {"QueryResponse": {"totalCount": 0}}, {"QueryResponse": {"totalCount": 1}},
        ]), self.assertRaises(catalog.AttemptError):
            self.provider.items()

    def test_no_redirect_transport_rejects_wrong_origin_method_and_resource(self):
        bad = (("https://example.invalid/v3/company/realm/item", "GET"),
               ("http://quickbooks.api.intuit.com/v3/company/realm/item", "POST"),
               ("https://user@quickbooks.api.intuit.com/v3/company/realm/item", "POST"),
               ("https://quickbooks.api.intuit.com:444/v3/company/realm/item", "POST"),
               ("https://quickbooks.api.intuit.com/v3/company/realm/invoice", "POST"),
               ("https://quickbooks.api.intuit.com/v3/company/realm/query", "POST"),
               ("https://quickbooks.api.intuit.com/v3/company/realm/item/I1", "DELETE"),
               ("https://quickbooks.api.intuit.com/v3/company/realm/item#fragment", "POST"))
        with mock.patch.object(backend.urllib.request, "build_opener") as opener:
            for url, method in bad:
                with self.assertRaises(catalog.AttemptError):
                    backend.qbo_catalog_transport(urllib.request.Request(url, method=method))
            opener.assert_not_called()

    def test_transport_uses_bounded_read_and_omits_raw_provider_errors(self):
        request = urllib.request.Request("https://quickbooks.api.intuit.com/v3/company/realm/item", method="POST")
        opener = mock.MagicMock()
        opener.open.side_effect = urllib.error.HTTPError(request.full_url, 400, "secret fixture", {},
                                                          io.BytesIO(b"private provider content"))
        with mock.patch.object(backend.urllib.request, "build_opener", return_value=opener) as factory:
            with self.assertRaises(catalog.AttemptError) as caught:
                backend.qbo_catalog_transport(request)
            self.assertNotIn("private", str(caught.exception))
            self.assertNotIn("secret", str(caught.exception))
            self.assertIsInstance(factory.call_args.args[0], backend.QBOReadNoRedirect)
        for body in (b"not json", b"[]", b"x" * (1024 * 1024 + 1)):
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.status = 200
            response.read.return_value = body
            opener.open.side_effect = None
            opener.open.return_value = response
            with mock.patch.object(backend.urllib.request, "build_opener", return_value=opener), self.assertRaises(catalog.AttemptError):
                backend.qbo_catalog_transport(request)
            response.read.assert_called_once_with(1024 * 1024 + 1)
            self.assertEqual(opener.open.call_args.kwargs["timeout"], 20)

    def test_redirect_handler_does_not_forward_authorization(self):
        handler = backend.QBOReadNoRedirect()
        result = handler.redirect_request(None, None, 302, "redirect", {}, "https://example.invalid")
        self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()
