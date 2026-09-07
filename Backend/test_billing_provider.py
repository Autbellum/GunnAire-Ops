import copy
import io
import json
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid
from unittest import mock

from Backend import billing_provider as provider
from Backend import billing_publications as billing


class BillingProviderTests(unittest.TestCase):
    def setUp(self):
        self.context = {"realm_id": "realm", "environment": "sandbox", "grant_fingerprint": "fixture"}
        self.check, self.bearer, self.send = mock.Mock(), mock.Mock(return_value="fixture-bearer"), mock.Mock()
        self.api = provider.BillingQBOProvider(self.context, self.check, self.bearer, self.send)
        self.document_id, self.publication_id = str(uuid.uuid4()), str(uuid.uuid4())
        self.document = {"CustomerRef": {"value": "C1"}, "TxnDate": "2026-09-07", "EmailStatus": "NotSet",
            "PrivateNote": "GunnAire Invoice ID: " + self.document_id.upper() + "\nGunnAire Publication: " + self.publication_id,
            "Line": [{"Amount": 189, "DetailType": "SalesItemLineDetail", "SalesItemLineDetail": {
                "ItemRef": {"value": "I1"}, "Qty": 1, "UnitPrice": 189, "TaxCodeRef": {"value": "NON"}}}]}
        for flag in ("AllowOnlineACHPayment", "AllowOnlineCreditCardPayment", "AllowOnlineAffirmPayment", "AllowOnlinePayPalPayment"):
            self.document[flag] = False
        self.request_id = "ga-invoice-" + self.document_id
        self.preferences = {"CurrencyPrefs": {"HomeCurrency": {"value": "USD"}, "MultiCurrencyEnabled": False},
                            "TaxPrefs": {"UsingSalesTax": True, "PartnerTaxEnabled": True}}
        self.customer = {"Id": "C1", "Active": True}
        self.item = {"Id": "I1", "Active": True, "Type": "Service"}
        self.company = {"Id": "1", "Country": "USA"}

    def preflight_transport(self, request):
        path = urllib.parse.urlsplit(request.full_url).path
        if path.endswith("/preferences"):
            return {"Preferences": copy.deepcopy(self.preferences)}
        if path.endswith("/companyinfo/realm"):
            return {"CompanyInfo": copy.deepcopy(self.company)}
        if path.endswith("/customer/C1"):
            return {"Customer": copy.deepcopy(self.customer)}
        if path.endswith("/item/I1"):
            return {"Item": copy.deepcopy(self.item)}
        self.fail("Unexpected preflight resource: " + path)

    def test_read_uses_only_original_origin_and_cached_in_memory_bearer(self):
        self.send.side_effect = [{"Invoice": {"Id": "D1"}}, {"Invoice": {"Id": "D2"}}]
        self.api.read("Invoice", "D1")
        self.api.read("Invoice", "D2")
        self.assertEqual(self.bearer.call_count, 1)
        self.assertEqual(self.send.call_args_list[0].args[0].full_url, "https://sandbox-quickbooks.api.intuit.com/v3/company/realm/invoice/D1?minorversion=75")
        self.assertEqual(self.send.call_args.args[0].get_method(), "GET")
        self.assertNotIn("fixture-bearer", self.send.call_args.args[0].full_url)

    def test_resource_and_reference_validation_precede_credentials(self):
        for kind, identifier in (("Payment", "1"), ("Invoice", "../other"), ("Invoice", "1?sendTo=other"), ("Invoice", "")):
            with self.assertRaises(billing.AttemptError):
                self.api.read(kind, identifier)
        with self.assertRaises(billing.AttemptError):
            self.api.request("invoice/D1/send")
        with self.assertRaises(billing.AttemptError):
            provider.BillingQBOProvider({**self.context, "environment": "unknown"}, self.check, self.bearer)
        self.bearer.assert_not_called()
        self.send.assert_not_called()

    def test_original_draft_claim_immediately_precedes_post_after_refresh(self):
        events = []
        self.bearer.side_effect = lambda *args: events.append("refresh") or "fixture-bearer"
        def send(request):
            events.append("send")
            self.assertEqual(events[-2], "claim")
            self.assertEqual(request.get_method(), "POST")
            self.assertEqual(json.loads(request.data), self.document)
            self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)["requestid"], [self.request_id])
            return {"Invoice": {"Id": "D1"}}
        self.send.side_effect = send
        self.api.write("Invoice", self.document, self.request_id, lambda: events.append("claim"))
        self.assertLess(events.index("refresh"), events.index("claim"))

    def test_refresh_failure_or_revoked_claim_never_posts(self):
        claim = mock.Mock()
        self.bearer.side_effect = billing.failure("unavailable", "Fixture unavailable.")
        with self.assertRaises(billing.AttemptError):
            self.api.write("Invoice", self.document, self.request_id, claim)
        claim.assert_not_called()
        self.send.assert_not_called()
        self.bearer.side_effect = None
        claim.side_effect = billing.failure("revoked", "Fixture revoked.")
        with self.assertRaises(billing.AttemptError):
            self.api.write("Invoice", self.document, self.request_id, claim)
        self.send.assert_not_called()

    def test_late_authorization_loss_cannot_return_provider_confirmation(self):
        def send(request):
            self.check.side_effect = billing.failure("revoked", "Fixture revoked.")
            return {"Invoice": {"Id": "D1"}}
        self.send.side_effect = send
        with self.assertRaises(billing.AttemptError):
            self.api.write("Invoice", self.document, self.request_id, lambda: None)
        self.assertEqual(self.send.call_count, 1)

    def test_write_rejects_wrong_lineage_request_id_extra_financial_fields_and_auto_email(self):
        for change in ({"PrivateNote": "forged"}, {"Balance": 100}, {"EmailStatus": "NeedToSend"},
                       {"AllowOnlineACHPayment": True}, {"AllowOnlineCreditCardPayment": None}, {"Id": "D1"},
                       {"Deposit": 50}, {"TotalAmt": 20}, {"LinkedTxn": [{"TxnType": "Payment", "TxnId": "P1"}]}):
            with self.subTest(change=change), self.assertRaises(billing.AttemptError):
                self.api.write("Invoice", {**self.document, **change}, self.request_id, lambda: None)
        for request_id in ("arbitrary", "ga-invoice-" + str(uuid.uuid4()), "ga-update-" + self.publication_id):
            with self.assertRaises(billing.AttemptError):
                self.api.write("Invoice", self.document, request_id, lambda: None)
        self.bearer.assert_not_called()
        self.send.assert_not_called()

    def test_preflight_verifies_original_us_company_customer_item_without_repricing(self):
        self.send.side_effect = self.preflight_transport
        self.item["UnitPrice"] = 999  # A new pricebook price cannot reprice a sold line.
        self.api.preflight(self.document)
        self.assertEqual(self.document["Line"][0]["SalesItemLineDetail"]["UnitPrice"], 189)
        self.assertEqual(self.send.call_count, 4)
        self.assertTrue(all(call.args[0].get_method() == "GET" for call in self.send.call_args_list))

    def test_inactive_or_wrong_customer_item_and_unknown_locale_fail_preflight(self):
        self.send.side_effect = self.preflight_transport
        for target, key, value in ((self.customer, "Active", False), (self.customer, "Id", "C2"),
                                   (self.item, "Active", None), (self.item, "Type", "Group"), (self.company, "Country", "CA")):
            original = target[key]
            target[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(billing.AttemptError):
                self.api.preflight(self.document)
            target[key] = original

    def test_multicurrency_requires_explicit_matching_usd_document_and_customer(self):
        self.send.side_effect = self.preflight_transport
        self.preferences["CurrencyPrefs"]["MultiCurrencyEnabled"] = True
        with self.assertRaises(billing.AttemptError):
            self.api.preflight(self.document)
        self.document["CurrencyRef"] = {"value": "USD"}
        for currency in (None, {"value": "CAD"}):
            self.customer["CurrencyRef"] = currency
            with self.assertRaises(billing.AttemptError):
                self.api.preflight(self.document)
        self.customer["CurrencyRef"] = {"value": "USD"}
        self.api.preflight(self.document)

    def test_taxable_work_requires_automated_tax_and_both_verified_locations(self):
        self.send.side_effect = self.preflight_transport
        self.document["Line"][0]["SalesItemLineDetail"]["TaxCodeRef"]["value"] = "TAX"
        with self.assertRaises(billing.AttemptError):
            self.api.preflight(self.document)
        address = {"Line1": "42 Fixture Street", "City": "Raleigh", "CountrySubDivisionCode": "NC", "PostalCode": "27601"}
        self.document["ShipFromAddr"], self.document["ShipAddr"] = dict(address), dict(address)
        self.api.preflight(self.document)
        for key in ("UsingSalesTax", "PartnerTaxEnabled"):
            self.preferences["TaxPrefs"][key] = False
            with self.assertRaises(billing.AttemptError):
                self.api.preflight(self.document)
            self.preferences["TaxPrefs"][key] = True

    def test_document_census_checks_all_pages_counts_and_duplicate_ids(self):
        values = [{"Id": str(index)} for index in range(26)]
        def send(request):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)["query"][0]
            if "COUNT(*)" in query:
                return {"QueryResponse": {"totalCount": 26}}
            self.assertIn("ORDERBY TxnDate", query)
            start = 26 if "STARTPOSITION 26 " in query else 1
            page = values[start - 1:start + 24]
            return {"QueryResponse": {"Invoice": page, "startPosition": start, "maxResults": len(page)}}
        self.send.side_effect = send
        self.assertEqual(self.api.documents("Invoice"), values)
        self.assertEqual(self.send.call_count, 4)
        values[-1] = values[0]
        with self.assertRaises(billing.AttemptError):
            self.api.documents("Invoice")

    def test_malformed_partial_changed_and_excessive_census_is_not_absence(self):
        for total in (None, True, -1, 100001, float("nan")):
            self.send.return_value = {"QueryResponse": {"totalCount": total}}
            with self.assertRaises(billing.AttemptError):
                self.api.documents("Invoice")
        for page in ({"Invoice": []}, {"Invoice": [{"Id": "D1"}], "startPosition": 2, "maxResults": 1},
                     {"Invoice": [None], "startPosition": 1, "maxResults": 1}):
            self.send.side_effect = [{"QueryResponse": {"totalCount": 1}}, {"QueryResponse": page}]
            with self.assertRaises(billing.AttemptError):
                self.api.documents("Invoice")
        self.send.side_effect = [{"QueryResponse": {"totalCount": 0}}, {"QueryResponse": {"totalCount": 1}}]
        with self.assertRaises(billing.AttemptError):
            self.api.documents("Invoice")

    def test_transport_rejects_other_origins_send_void_delete_and_arbitrary_query_actions(self):
        prefix = "https://quickbooks.api.intuit.com/v3/company/realm/"
        invalid = (("https://example.invalid/v3/company/realm/invoice", "POST"), (prefix + "invoice/D1/send", "POST"),
                   (prefix + "invoice?operation=void", "POST"), (prefix + "invoice?operation=delete", "POST"),
                   (prefix + "payment", "POST"), (prefix + "invoice/D1", "DELETE"), (prefix + "query", "POST"),
                   (prefix + "invoice?minorversion=75&requestid=bad", "POST"), (prefix + "invoice/D1#other", "GET"),
                   (prefix.replace("https:", "http:") + "invoice", "POST"))
        with mock.patch.object(provider.urllib.request, "build_opener") as opener:
            for url, method in invalid:
                with self.assertRaises(billing.AttemptError):
                    provider.transport(urllib.request.Request(url, method=method))
            opener.assert_not_called()

    def test_transport_uses_no_redirect_bounded_responses_and_sanitized_errors(self):
        request = urllib.request.Request("https://quickbooks.api.intuit.com/v3/company/realm/invoice/D1?minorversion=75")
        opener = mock.MagicMock()
        opener.open.side_effect = urllib.error.HTTPError(request.full_url, 400, "fixture secret", {}, io.BytesIO(b"private provider body"))
        with mock.patch.object(provider.urllib.request, "build_opener", return_value=opener) as factory:
            with self.assertRaises(billing.AttemptError) as caught:
                provider.transport(request)
            self.assertNotIn("secret", str(caught.exception))
            self.assertNotIn("private", str(caught.exception))
            self.assertIsInstance(factory.call_args.args[0], provider.NoRedirect)
        for body in (b"[]", b"not json", b"x" * (1024 * 1024 + 1)):
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.status, response.read.return_value = 200, body
            opener.open.side_effect, opener.open.return_value = None, response
            with mock.patch.object(provider.urllib.request, "build_opener", return_value=opener), self.assertRaises(billing.AttemptError):
                provider.transport(request)
            response.read.assert_called_once_with(1024 * 1024 + 1)
            self.assertEqual(opener.open.call_args.kwargs["timeout"], 20)


if __name__ == "__main__":
    unittest.main()
