"""Read-only collection review, exercised through the real application HTTP boundary."""
import copy
import json
import unittest
import urllib.parse
import uuid
from unittest import mock

from Backend import gunnaire_backend as backend, billing_assignments, payment_attempts
from Backend import test_payment_attempts as fixtures
from Backend import field_payment_review, test_payment_provider_read as provider_fixtures


class FieldPaymentReviewTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.PaymentAttemptTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.customer_id = str(uuid.uuid4())
        self.fixture.invoice.update(SyncToken="2", DocNumber="1069", TxnDate="2026-09-08", Balance=60,
                                    LinkedTxn=[{"TxnId": "payment-one", "TxnType": "Payment"}])
        self.fixture.accounting["payment-one"] = {
            "Id": "payment-one", "SyncToken": "0", "TxnDate": "2026-09-08", "TotalAmt": 40,
            "UnappliedAmt": 0, "CustomerRef": {"value": "fixture-customer"},
            "Line": [{"Amount": 40, "LinkedTxn": [{"TxnId": "fixture-invoice", "TxnType": "Invoice"}]}],
            "PrivateNote": "PRIVATE-NOTE-MUST-NOT-LEAVE", "CreditCardPayment": {"secret": "PRIVATE-CARD"},
        }
        with backend.db() as connection:
            scope = (self.fixture.company_id, "fixture-realm", "sandbox")
            connection.execute("INSERT INTO customer_entity_mappings VALUES (?,?,?,?,?)",
                               (*scope, self.customer_id, "fixture-customer"))
            connection.execute("INSERT INTO billing_entity_mappings VALUES (?,?,?,?,?,?,?)",
                               (*scope, "Invoice", self.fixture.invoice_id, self.customer_id, "fixture-invoice"))
            revision = billing_assignments.connection_revision(payment_attempts.grant_fingerprint(
                connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()))
        self.query = dict(companyID=self.fixture.company_id, realmID="fixture-realm", environment="sandbox",
                          invoiceID=self.fixture.invoice_id, localCustomerID=self.customer_id,
                          invoiceQuickBooksID="fixture-invoice", customerQuickBooksID="fixture-customer",
                          connectionRevision=revision)

    def request(self, query=None, **kwargs):
        return self.fixture.request("/api/field-payment-review?" + urllib.parse.urlencode(self.query if query is None else query), **kwargs)

    def test_reads_exact_linked_payments_twice_without_mutation_or_private_payload(self):
        status, body = self.request()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["invoiceNumber"], "1069")
        self.assertNotEqual(body["invoiceNumber"], body["invoiceQuickBooksID"])
        self.assertEqual(body["balanceCents"], 6000)
        self.assertEqual(body["payments"][0]["appliedCents"], 4000)
        self.assertFalse(body["fundsSettlementVerified"])
        self.assertEqual([(category, identifier) for category, identifier, _ in self.fixture.reads],
                         [("invoice", "fixture-invoice"), ("accounting", "payment-one"),
                          ("accounting", "payment-one"), ("invoice", "fixture-invoice")])
        for forbidden in ("PRIVATE-", "fixture-ciphertext", "fixture-client", "grant_fingerprint", "actor_email", "CreditCardPayment", "PrivateNote"):
            self.assertNotIn(forbidden, json.dumps(body))
        self.assertEqual(self.fixture.count(), 0)

    def test_accounting_and_assigned_field_can_review_without_device_qbo_credentials(self):
        self.fixture.assignment()
        for role in ("Accounting", "Field Technician"):
            status, body = self.request(role=role)
            self.assertEqual(status, 200, body)
            self.assertEqual(body["authority"], "assigned" if role == "Field Technician" else "office")

    def test_field_context_resolves_server_connection_without_mobile_oauth(self):
        self.fixture.assignment()
        query = {key: value for key, value in self.query.items() if key not in ("realmID", "environment", "connectionRevision")}
        path = "/api/field-payment-review/context?" + urllib.parse.urlencode(query)
        status, scope = self.fixture.request(path, role="Field Technician")
        self.assertEqual(status, 200, scope)
        self.assertEqual(scope, self.query)
        self.assertEqual(self.fixture.reads, [])
        self.assertEqual(self.request(scope, role="Field Technician")[0], 200)

    def test_unassigned_field_dispatcher_and_standard_cannot_read_provider(self):
        for role in ("Field Technician", "Dispatcher", "Standard"):
            status, _ = self.request(role=role)
            self.assertEqual(status, 403)
        self.assertEqual(self.fixture.reads, [])

    def test_missing_application_session_is_not_replaced_by_static_api_token(self):
        self.assertEqual(self.request(token="invalid-session")[0], 401)
        with mock.patch.multiple(backend, AUTH_MODE="api-token", API_TOKEN="fixture-static-token"):
            self.assertEqual(self.request(token="fixture-static-token")[0], 403)
        self.assertEqual(self.fixture.reads, [])

    def test_access_log_omits_invoice_customer_and_connection_query(self):
        with mock.patch("builtins.print") as output:
            self.assertEqual(self.request()[0], 200)
        messages = " ".join(str(call) for call in output.call_args_list)
        self.assertIn("/api/field-payment-review HTTP", messages)
        for value in self.query.values():
            self.assertNotIn(value, messages)

    def test_wrong_business_connection_customer_invoice_and_epoch_stop_before_provider(self):
        for key, value in (("companyID", str(uuid.uuid4())), ("realmID", "other-realm"),
                           ("environment", "production"), ("localCustomerID", str(uuid.uuid4())),
                           ("invoiceID", str(uuid.uuid4())), ("invoiceQuickBooksID", "another-invoice"),
                           ("customerQuickBooksID", "another-customer"), ("connectionRevision", "0" * 64)):
            with self.subTest(key=key):
                status, _ = self.request({**self.query, key: value})
                self.assertIn(status, (403, 409))
        self.assertEqual(self.fixture.reads, [])

    def test_strict_query_and_read_only_method(self):
        for query in ({**self.query, "secret": "ignored?"}, {**self.query, "invoiceID": "../other"},
                      {key: value for key, value in self.query.items() if key != "connectionRevision"}):
            self.assertEqual(self.request(query)[0], 400)
        path = "/api/field-payment-review?" + urllib.parse.urlencode(self.query) + "&invoiceID=" + self.query["invoiceID"]
        self.assertEqual(self.fixture.request(path)[0], 400)
        self.assertEqual(self.request(payload={})[0], 404)
        self.assertEqual(self.fixture.reads, [])

    def test_missing_or_blank_number_never_substitutes_provider_id(self):
        for value in (None, "", "   "):
            self.fixture.invoice["DocNumber"] = value
            status, body = self.request()
            self.assertEqual(status, 200, body)
            self.assertIsNone(body["invoiceNumber"])

    def test_invalid_number_date_money_currency_and_identity_do_not_succeed(self):
        original = copy.deepcopy(self.fixture.invoice)
        for change in ({"DocNumber": "bad\nnumber"}, {"DocNumber": "a" * 22}, {"TxnDate": "2026-02-31"},
                       {"Balance": True}, {"Balance": 100.001}, {"Balance": 101}, {"TotalAmt": float("inf")},
                       {"CurrencyRef": {"value": "EUR"}}, {"Id": "other"},
                       {"CustomerRef": {"value": "other"}}, {"SyncToken": None}):
            with self.subTest(change=change):
                self.fixture.invoice = {**original, **change}
                self.assertEqual(self.request()[0], 409)

    def test_duplicate_or_malformed_invoice_links_fail_without_partial_success(self):
        for links in ([{"TxnId": "payment-one", "TxnType": "Payment"}] * 2,
                      [{"TxnId": "../payment", "TxnType": "Payment"}], "bad"):
            self.fixture.invoice["LinkedTxn"] = links
            self.assertEqual(self.request()[0], 409)

    def test_unrelated_invoice_link_is_not_fetched_or_disclosed(self):
        self.fixture.invoice["LinkedTxn"].append({"TxnId": "private-estimate", "TxnType": "Estimate"})
        status, body = self.request()
        self.assertEqual(status, 200, body)
        self.assertNotIn("private-estimate", json.dumps(body))
        self.assertFalse(any(identifier == "private-estimate" for _, identifier, _ in self.fixture.reads))

    def test_multi_invoice_payment_returns_only_this_invoice_allocation(self):
        payment = self.fixture.accounting["payment-one"]
        payment["TotalAmt"] = 90
        payment["Line"].append({"Amount": 50, "LinkedTxn": [{"TxnId": "private-other-invoice", "TxnType": "Invoice"}]})
        status, body = self.request()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["payments"][0]["appliedCents"], 4000)
        self.assertNotIn("private-other-invoice", json.dumps(body))

    def test_credit_allocation_is_not_claimed_as_cash_or_settlement(self):
        payment = self.fixture.accounting["payment-one"]
        payment["TotalAmt"] = 0
        payment["Line"].append({"Amount": 40, "LinkedTxn": [{"TxnId": "credit-one", "TxnType": "CreditMemo"}]})
        status, body = self.request()
        self.assertEqual(status, 200, body)
        self.assertTrue(body["payments"][0]["includesCreditOrAdjustment"])
        self.assertFalse(body["fundsSettlementVerified"])

    def test_ambiguous_line_or_wrong_payment_customer_fails(self):
        original = copy.deepcopy(self.fixture.accounting["payment-one"])
        for change in ({"CustomerRef": {"value": "other"}}, {"Id": "other"},
                       {"Line": [{"Amount": 40, "LinkedTxn": [{"TxnId": "fixture-invoice", "TxnType": "Invoice"},
                                                                 {"TxnId": "other", "TxnType": "Invoice"}]}]},
                       {"Line": []}, {"Line": "bad"}):
            self.fixture.accounting["payment-one"] = {**original, **change}
            self.assertEqual(self.request()[0], 409)

    def test_invoice_or_payment_change_during_reads_requires_refresh(self):
        original_reader = self.fixture.provider
        for changed_category in ("invoice", "accounting"):
            count = {}
            def reader(context, category, record_id, **kwargs):
                value = original_reader(context, category, record_id, **kwargs)
                count[category] = count.get(category, 0) + 1
                if category == changed_category and count[category] == 2:
                    value["SyncToken"] = "99"
                return value
            with mock.patch.object(backend, "read_payment_provider_record", side_effect=reader):
                status, body = self.request()
                self.assertEqual(status, 409, body)
                self.assertEqual(body["code"], "review_changed")

    def test_access_mapping_grant_and_assignment_rechecked_after_network(self):
        self.fixture.assignment()
        statements = (
            "UPDATE auth_sessions SET revoked_at='2026-09-08'",
            "UPDATE users SET is_active=0",
            "UPDATE users SET role='Standard'",
            "DELETE FROM billing_entity_mappings",
            "DELETE FROM customer_entity_mappings",
            "UPDATE qbo_connections SET authorized_at='replacement'",
            "UPDATE field_payment_assignments SET status='cancelled'",
        )
        # Isolate each mutation using a fresh fixture; no production database is opened.
        for statement in statements:
            with self.subTest(statement=statement):
                with backend.db() as connection:
                    backup = {table: [dict(row) for row in connection.execute("SELECT * FROM " + table)]
                              for table in ("auth_sessions", "users", "billing_entity_mappings", "customer_entity_mappings", "qbo_connections", "field_payment_assignments")}
                def reader(context, category, identifier, **kwargs):
                    result = self.fixture.provider(context, category, identifier, **kwargs)
                    with backend.db() as connection:
                        connection.execute(statement)
                    return result
                with mock.patch.object(backend, "read_payment_provider_record", side_effect=reader):
                    status, _ = self.request(role="Field Technician")
                    self.assertIn(status, (403, 409))
                with backend.db() as connection:
                    for table, rows in backup.items():
                        connection.execute("DELETE FROM " + table)
                        for row in rows:
                            connection.execute("INSERT INTO " + table + " (" + ",".join(row) + ") VALUES (" + ",".join("?" for _ in row) + ")", tuple(row.values()))

    def test_completed_assignment_is_reviewable_but_not_a_new_collection_allowance(self):
        self.fixture.assignment()
        with backend.db() as connection:
            connection.execute("UPDATE field_payment_assignments SET status='completed',collected_amount=100")
        status, body = self.request(role="Field Technician")
        self.assertEqual(status, 200, body)
        self.assertEqual(body["collectionLimitCents"], 0)

    def test_active_attempt_blocks_more_collection_but_can_be_reviewed(self):
        self.fixture.reserve()
        status, body = self.request()
        self.assertEqual(status, 200, body)
        self.assertTrue(body["hasOpenAttempt"])
        self.assertEqual(body["collectionLimitCents"], 0)

    def test_newer_assignment_to_another_collector_revokes_stale_assignment(self):
        self.fixture.assignment()
        with backend.db() as connection:
            connection.execute("""INSERT INTO field_payment_assignments
                (id,invoice_id,customer_name,amount,assigned_to,assigned_by,status,created_at)
                VALUES (?,?,?,100,?,?,'accepted','2099-01-01')""",
                (str(uuid.uuid4()), self.fixture.invoice_id, "Fixture", "another@example.invalid", "admin@example.invalid"))
        self.assertEqual(self.request(role="Field Technician")[0], 403)
        self.assertEqual(self.fixture.reads, [])

    def test_provider_identity_marker_must_match_original_local_invoice(self):
        self.fixture.invoice["PrivateNote"] = "GunnAire invoice ID: " + str(uuid.uuid4())
        self.assertEqual(self.request()[0], 409)
        self.fixture.invoice["PrivateNote"] = "GunnAire invoice ID: " + self.fixture.invoice_id
        self.assertEqual(self.request()[0], 200)

    def test_bounded_review_timeout_and_payment_count_do_not_return_partial_results(self):
        clock = iter([0, 61])
        service = field_payment_review.FieldPaymentReview(backend.db, self.fixture.provider,
            backend.record_audit_event, monotonic=lambda: next(clock))
        with self.assertRaises(payment_attempts.AttemptError) as raised:
            service.review(self.fixture.sessions["Admin"], self.query)
        self.assertEqual(raised.exception.code, "review_timeout")
        self.assertEqual(self.fixture.reads, [])
        self.fixture.invoice["LinkedTxn"] = [{"TxnId": str(i), "TxnType": "Payment"} for i in range(33)]
        status, body = self.request()
        self.assertEqual(status, 409)
        self.assertEqual(body["code"], "review_limit")
        self.assertEqual(len(self.fixture.reads), 1)

    def test_provider_failure_is_sanitized_and_does_not_create_a_payment(self):
        with mock.patch.object(backend, "read_payment_provider_record", side_effect=RuntimeError("PRIVATE_PROVIDER_BODY")):
            status, body = self.request()
        self.assertEqual(status, 503)
        self.assertNotIn("PRIVATE", json.dumps(body))
        self.assertEqual(self.fixture.count(), 0)


class FieldPaymentReviewProviderBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.fixture = provider_fixtures.PaymentProviderReadTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)

    def test_revoked_access_before_refresh_never_loads_or_sends_provider_credentials(self):
        def check():
            raise payment_attempts.AttemptError("access_denied", "Fixture denial.", 403)
        with mock.patch.object(backend, "qbo_payment_read_transport") as transport:
            with self.assertRaises(payment_attempts.AttemptError):
                backend.read_payment_provider_record(self.fixture.context, "invoice", "invoice-one", authorize=check)
            self.fixture.oauth_mock.assert_not_called()
            transport.assert_not_called()

    def test_revocation_during_refresh_prevents_provider_get(self):
        allowed = True
        def refresh(*args):
            nonlocal allowed
            allowed = False
            return 200, {"access_token": "fixture-access", "refresh_token": "fixture-rotated", "expires_in": 3600}
        def check():
            if not allowed:
                raise payment_attempts.AttemptError("access_denied", "Fixture denial.", 403)
        self.fixture.oauth_mock.side_effect = refresh
        with mock.patch.object(backend, "qbo_payment_read_transport") as transport:
            with self.assertRaises(payment_attempts.AttemptError):
                backend.read_payment_provider_record(self.fixture.context, "invoice", "invoice-one", authorize=check)
            transport.assert_not_called()

    def test_revocation_during_provider_get_discards_reply(self):
        allowed = True
        def read(request):
            nonlocal allowed
            allowed = False
            return 200, {"Invoice": {"Id": "invoice-one"}}
        def check():
            if not allowed:
                raise payment_attempts.AttemptError("access_denied", "Fixture denial.", 403)
        with mock.patch.object(backend, "qbo_payment_read_transport", side_effect=read):
            with self.assertRaises(payment_attempts.AttemptError):
                backend.read_payment_provider_record(self.fixture.context, "invoice", "invoice-one", authorize=check)


if __name__ == "__main__":
    unittest.main()
