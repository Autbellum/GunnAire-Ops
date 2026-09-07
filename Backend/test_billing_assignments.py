from __future__ import annotations

import copy
import json
import sqlite3
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import billing_publications as billing
from Backend import billing_assignments as assignments
from Backend.test_billing_publications import BillingFixture


class BillingAssignmentTests(BillingFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.job_id = str(uuid.uuid4())
        self.jobs = self.publisher.assignments
        self.preflight.return_value = {"I1": {"Id": "I1", "Active": True, "Type": "Service", "UnitPrice": 189, "Taxable": False}}

    def assignment(self, **changes):
        return {"companyID": self.company, "realmID": "realm", "environment": "sandbox", "serviceCallID": self.job_id,
                "localCustomerID": self.customer_id, "technicianEmails": [self.email("Field Technician")], "enabled": True,
                "expectedRevision": 0, "operationID": str(uuid.uuid4()), **changes}

    def save_assignment(self, payload=None, role="Dispatcher"):
        return self.jobs.save(self.sessions[role], payload or self.assignment())

    def job_scope(self, **changes):
        return {key: value for key, value in self.assignment(**changes).items() if key in ("companyID", "realmID", "environment", "serviceCallID")}

    def field_payload(self, revision=1, **changes):
        return self.payload(**{"serviceCallID": self.job_id, "assignmentRevision": revision, **changes})

    @contextmanager
    def http(self):
        factory = lambda context, authorize, bearer: self.provider(context, authorize)
        with mock.patch.object(backend, "BillingQBOProvider", side_effect=factory), mock.patch.object(backend, "qbo_authorized_bearer") as credentials:
            server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            def request(path, payload=None, role="Admin", *, token=None, raw=None):
                req = urllib.request.Request("http://127.0.0.1:" + str(server.server_port) + path,
                    data=raw if raw is not None else json.dumps(payload).encode() if payload is not None else None,
                    headers={"Authorization": "Bearer " + (token or self.tokens[role]), "Content-Type": "application/json"})
                try:
                    with urllib.request.urlopen(req, timeout=5) as response:
                        return response.status, json.load(response)
                except urllib.error.HTTPError as error:
                    return error.code, json.load(error)
            try:
                yield request
                credentials.assert_not_called()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)

    def test_dispatcher_assignment_allows_ordinary_field_invoice_and_estimate(self):
        result = self.save_assignment()
        self.assertTrue(result["assignment"]["usable"])
        self.assertEqual(result["assignment"]["revision"], 1)
        published = self.publish(self.field_payload(), "Field Technician")
        self.assertEqual(published["document"]["TotalAmt"], 189)
        estimate = self.field_payload(documentType="Estimate", localDocumentID=str(uuid.uuid4()))
        estimate["document"].pop("DueDate")
        self.publish(estimate, "Field Technician")
        self.assertEqual([value[0] for value in self.writes], ["Invoice", "Estimate"])

    def test_only_current_admin_or_dispatcher_can_establish_field_authority(self):
        for role in ("Accounting", "Field Technician", "Standard"):
            self.expect("dispatcher_required", lambda: self.save_assignment(role=role))
        self.save_assignment(role="Admin")
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Standard' WHERE role='Admin'")
        with mock.patch.object(backend, "PRIMARY_ADMIN_EMAIL", self.email("Admin")):
            self.expect("dispatcher_required", lambda: self.save_assignment(self.assignment(expectedRevision=1), "Admin"))

    def test_roster_requires_distinct_active_exact_field_accounts(self):
        for roster in ([], [self.email("Admin")], ["missing@example.invalid"], [self.email("Field Technician")] * 2,
                       ["Field.Technician@example.invalid"], [" bad@example.invalid"], [True], "field@example.invalid"):
            with self.subTest(roster=roster), self.assertRaises(billing.AttemptError):
                self.save_assignment(self.assignment(technicianEmails=roster))
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0 WHERE role='Field Technician'")
        self.expect("invalid_roster", self.save_assignment)

    def test_strict_assignment_values_reject_client_authority_and_invalid_revisions(self):
        for change in ({"role": "Admin"}, {"grant": "client"}, {"enabled": 1}, {"expectedRevision": True},
                       {"expectedRevision": -1}, {"expectedRevision": 2147483647}, {"serviceCallID": "../job"},
                       {"operationID": ""}, {"localCustomerID": None}, {"environment": "unknown"}):
            with self.subTest(change=change), self.assertRaises(billing.AttemptError):
                self.save_assignment(self.assignment(**change))

    def test_assignment_company_realm_environment_and_job_are_isolated(self):
        for changes, code in (({"companyID": str(uuid.uuid4())}, "company_changed"), ({"realmID": "other"}, "provider_changed"),
                              ({"environment": "production"}, "provider_changed")):
            self.expect(code, lambda: self.save_assignment(self.assignment(**changes)))
        self.save_assignment()
        self.expect("review_required", lambda: self.publish(self.field_payload(serviceCallID=str(uuid.uuid4())), "Field Technician"))
        self.expect("review_required", lambda: self.publish(self.field_payload(localCustomerID=str(uuid.uuid4())), "Field Technician"))
        self.assertFalse(self.writes)

    def test_server_roster_not_client_job_claim_authorizes_field_work(self):
        self.expect("review_required", lambda: self.publish(self.field_payload(), "Field Technician"))
        for change in ({"serviceCallID": self.job_id}, {"assignmentRevision": 1}, {"serviceCallID": self.job_id, "assignmentRevision": True}):
            self.expect("invalid_request", lambda: self.publish(self.payload(**change), "Field Technician"))
        self.save_assignment()
        self.expect("review_required", lambda: self.publish(self.field_payload(revision=2), "Field Technician"))

    def test_stable_operation_replay_does_not_increment_or_rewrite_assignment(self):
        payload = self.assignment()
        first = self.save_assignment(payload)
        self.assertEqual(first, self.save_assignment(payload))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM billing_assignment_mutations").fetchone()[0], 1)
        self.expect("assignment_conflict", lambda: self.save_assignment({**payload, "enabled": False}))

    def test_stale_offline_edit_and_old_replay_cannot_restore_revoked_access(self):
        original = self.assignment()
        self.save_assignment(original)
        self.save_assignment(self.assignment(expectedRevision=1, enabled=False, technicianEmails=[]))
        self.expect("assignment_conflict", lambda: self.save_assignment(original))
        self.expect("assignment_conflict", lambda: self.save_assignment(self.assignment(expectedRevision=1)))
        self.expect("review_required", lambda: self.publish(self.field_payload(), "Field Technician"))
        result = self.jobs.read(self.admin, self.job_scope())["assignment"]
        self.assertEqual(result["revision"], 2)
        self.assertFalse(result["enabled"])

    def test_concurrent_dispatch_edits_have_exactly_one_winner(self):
        self.save_assignment()
        barrier = threading.Barrier(2)
        def change(enabled):
            barrier.wait(timeout=5)
            try:
                self.save_assignment(self.assignment(expectedRevision=1, enabled=enabled))
                return "saved"
            except billing.AttemptError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as executor:
            self.assertCountEqual(executor.map(change, [True, False]), ["saved", "assignment_conflict"])
        self.assertEqual(self.jobs.read(self.admin, self.job_scope())["assignment"]["revision"], 2)

    def test_assignment_customer_cannot_change_even_after_revocation(self):
        self.save_assignment()
        self.save_assignment(self.assignment(expectedRevision=1, enabled=False))
        self.expect("job_changed", lambda: self.save_assignment(self.assignment(expectedRevision=2, localCustomerID=str(uuid.uuid4()))))

    def test_reconnected_grant_requires_fresh_office_assignment_review(self):
        original = self.assignment()
        self.save_assignment(original)
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='replacement-grant'")
        self.assertFalse(self.jobs.read(self.admin, self.job_scope())["assignment"]["usable"])
        self.expect("assignment_conflict", lambda: self.save_assignment(original))
        self.expect("review_required", lambda: self.publish(self.field_payload(), "Field Technician"))
        self.save_assignment(self.assignment(expectedRevision=1))
        self.publish(self.field_payload(revision=2), "Field Technician")

    def test_approver_deactivation_or_role_removal_invalidates_field_access(self):
        self.save_assignment()
        for assignment in ("is_active=0", "is_active=1,role='Accounting'"):
            with backend.db() as connection:
                connection.execute("UPDATE users SET " + assignment + " WHERE email=?", (self.email("Dispatcher"),))
            self.expect("review_required", lambda: self.publish(self.field_payload(), "Field Technician"))

    def test_field_read_requires_current_membership_and_rejects_roster_enumeration(self):
        self.save_assignment()
        self.assertEqual(self.jobs.read(self.sessions["Field Technician"], self.job_scope())["assignment"]["serviceCallID"], self.job_id)
        for role in ("Accounting", "Standard"):
            self.expect("access_denied", lambda: self.jobs.read(self.sessions[role], self.job_scope()))
        self.expect("access_denied", lambda: self.jobs.read(self.sessions["Field Technician"], self.job_scope(serviceCallID=str(uuid.uuid4()))))
        self.save_assignment(self.assignment(expectedRevision=1, enabled=False))
        self.expect("access_denied", lambda: self.jobs.read(self.sessions["Field Technician"], self.job_scope()))

    def test_saved_roster_is_encrypted_and_public_metadata_excludes_grant_and_actor(self):
        result = self.save_assignment()
        with backend.db() as connection:
            row = dict(connection.execute("SELECT * FROM billing_job_assignments").fetchone())
            mutation = dict(connection.execute("SELECT * FROM billing_assignment_mutations").fetchone())
        self.assertNotIn("example.invalid", row["roster_ciphertext"])
        self.assertNotIn("example.invalid", json.dumps(mutation))
        self.assertEqual(row["roster_hash"], assignments.digest(row["roster_ciphertext"]))
        self.assertNotEqual(row["roster_hash"], assignments.digest([self.email("Field Technician")]))
        for hidden in ("grant_fingerprint", "approved_by", "ciphertext", "roster_hash", "operationID"):
            self.assertNotIn(hidden, json.dumps(result))
        with backend.db() as connection:
            connection.execute("UPDATE billing_job_assignments SET roster_hash='tampered'")
        self.expect("storage_unavailable", lambda: self.publish(self.field_payload(), "Field Technician"))

    def test_encrypted_roster_cannot_be_swapped_between_jobs(self):
        self.save_assignment()
        second_job = str(uuid.uuid4())
        self.save_assignment(self.assignment(serviceCallID=second_job))
        with backend.db() as connection:
            row = connection.execute("SELECT * FROM billing_job_assignments WHERE service_call_id=?", (second_job,)).fetchone()
            connection.execute("UPDATE billing_job_assignments SET roster_ciphertext=?,roster_hash=? WHERE service_call_id=?",
                               (row["roster_ciphertext"], row["roster_hash"], self.job_id))
        self.expect("storage_unavailable", lambda: self.publish(self.field_payload(), "Field Technician"))

    def test_failed_audit_rolls_back_assignment_and_idempotency_record(self):
        with mock.patch.object(self.jobs, "audit", side_effect=sqlite3.OperationalError("fixture")):
            with self.assertRaises(sqlite3.OperationalError):
                self.save_assignment()
        with backend.db() as connection:
            for table in ("billing_job_assignments", "billing_assignment_mutations"):
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM " + table).fetchone()[0], 0)

    def test_additive_assignment_schema_keeps_outer_transaction_uncommitted(self):
        with backend.db() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute("UPDATE users SET is_active=0")
            assignments.initialize_schema(connection)
            connection.rollback()
            self.assertEqual(connection.execute("SELECT MIN(is_active) FROM users").fetchone()[0], 1)

    def test_field_discount_or_changed_catalog_price_requires_exact_draft_approval(self):
        self.save_assignment()
        draft = self.field_payload()
        draft["document"]["Line"][0]["Amount"] = 175
        draft["document"]["Line"][0]["SalesItemLineDetail"]["UnitPrice"] = 175
        self.expect("price_review", lambda: self.publish(draft, "Field Technician"))
        self.assertFalse(self.writes)
        self.assertEqual(self.row()["state"], "reserved")
        self.publisher.approve_draft(self.admin, draft, self.email("Field Technician"))
        result = self.publish(draft, "Field Technician")
        self.assertEqual(result["document"]["Line"][0]["Amount"], 175)
        self.assertEqual(len(self.writes), 1)

    def test_field_discount_does_not_gain_authority_from_valid_catalog_lines(self):
        self.save_assignment()
        draft = self.field_payload()
        draft["document"]["Line"].append({"Amount": 5, "DetailType": "DiscountLineDetail", "DiscountLineDetail": {"PercentBased": False}})
        draft["document"]["ApplyTaxAfterDiscount"] = True
        self.expect("price_review", lambda: self.publish(draft, "Field Technician"))
        self.assertFalse(self.writes)

    def test_missing_changed_inactive_or_malformed_item_evidence_never_reprices(self):
        document = billing.validated_request(self.payload())["document"]
        original = copy.deepcopy(document)
        for change in ({"UnitPrice": 190}, {"Taxable": True}, {"UnitPrice": float("nan")}, {"UnitPrice": "189"},
                       {"Active": False}, {"Id": "other"}, {"Type": "Category"}, {"Taxable": None}):
            evidence = copy.deepcopy(self.preflight.return_value)
            evidence["I1"].update(change)
            self.expect("price_review", lambda: billing.verify_field_prices(document, evidence))
        for evidence in (None, {}, {"I1": {}}, {"I1": "189"}):
            self.expect("price_review", lambda: billing.verify_field_prices(document, evidence))
        self.assertEqual(document, original)

    def test_assignment_revoked_between_preflight_and_dispatch_prevents_post(self):
        self.save_assignment()
        self.before_write = lambda: self.save_assignment(self.assignment(expectedRevision=1, enabled=False))
        self.expect("review_required", lambda: self.publish(self.field_payload(), "Field Technician"))
        self.assertFalse(self.writes)
        self.assertEqual(self.row()["state"], "reserved")

    def test_expired_preflight_or_direct_claim_cannot_bypass_field_prices(self):
        self.save_assignment()
        row = self.publisher.reserve(self.sessions["Field Technician"], self.field_payload())
        self.expect("price_review", lambda: self.publisher.claim(self.sessions["Field Technician"], row["id"]))
        instant = datetime.now(timezone.utc)
        self.publisher.now = lambda: instant
        self.before_write = lambda: setattr(self.publisher, "now", lambda: instant + timedelta(seconds=31))
        self.expect("price_review", lambda: self.publish(self.field_payload(), "Field Technician"))
        self.assertFalse(self.writes)

    def test_revoked_exact_review_falls_back_only_to_current_catalog_prices(self):
        self.save_assignment()
        draft = self.field_payload()
        draft["document"]["Line"][0]["Amount"] = 170
        draft["document"]["Line"][0]["SalesItemLineDetail"]["UnitPrice"] = 170
        grant = self.publisher.approve_draft(self.admin, draft, self.email("Field Technician"))
        self.before_write = lambda: self.publisher.revoke_draft(self.admin, grant)
        self.expect("price_review", lambda: self.publish(draft, "Field Technician"))
        self.assertFalse(self.writes)

    def test_long_preflight_cannot_present_earlier_item_reads_as_fresh(self):
        self.save_assignment()
        instant = datetime.now(timezone.utc)
        self.publisher.now = lambda: instant
        def delayed(document):
            self.publisher.now = lambda: instant + timedelta(seconds=31)
            return self.preflight.return_value
        self.preflight.side_effect = delayed
        self.expect("price_review", lambda: self.publish(self.field_payload(), "Field Technician"))
        self.assertFalse(self.writes)

    def test_authenticated_http_uses_real_adapter_and_server_price_evidence_for_field_invoice(self):
        # All HTTP traffic is loopback. Every actual provider request is captured
        # by this fixed fixture transport, never sent to Intuit.
        self.save_assignment()
        captured, remote_records = [], []
        def transport(request):
            captured.append(request)
            path = urllib.parse.urlsplit(request.full_url).path
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)
            if path.endswith("/query"):
                if "COUNT(*)" in query["query"][0]:
                    return {"QueryResponse": {"totalCount": len(remote_records)}}
                return {"QueryResponse": {"Invoice": copy.deepcopy(remote_records), "startPosition": 1, "maxResults": len(remote_records)}}
            if path.endswith("/preferences"):
                return {"Preferences": {"CurrencyPrefs": {"HomeCurrency": {"value": "USD"}, "MultiCurrencyEnabled": False}}}
            if path.endswith("/companyinfo/realm"):
                return {"CompanyInfo": {"Id": "1", "Country": "USA"}}
            if path.endswith("/customer/C1"):
                return {"Customer": {"Id": "C1", "Active": True}}
            if path.endswith("/item/I1"):
                return {"Item": self.preflight.return_value["I1"]}
            if request.get_method() == "POST":
                self.assertEqual(path, "/v3/company/realm/invoice")
                remote = self.remote(json.loads(request.data))
                remote_records.append(remote)
                return {"Invoice": copy.deepcopy(remote)}
            if path.endswith("/invoice/D1"):
                return {"Invoice": copy.deepcopy(remote_records[0])}
            self.fail("Unexpected fixture request")
        from Backend.billing_provider import BillingQBOProvider
        with self.http() as request, mock.patch.object(backend, "BillingQBOProvider",
                side_effect=lambda context, check, bearer: BillingQBOProvider(context, check, lambda *args: "fixture-bearer", transport)):
            status, result = request("/api/billing-publications", self.field_payload(), "Field Technician")
            self.assertEqual(status, 200, result)
            self.assertEqual(result["document"]["TotalAmt"], 189)
            status, recovered = request("/api/billing-publications/" + result["publication"]["id"] + "/recover", {}, "Field Technician")
            self.assertEqual(status, 200, recovered)
            self.assertEqual(recovered["publication"]["id"], result["publication"]["id"])
        self.assertEqual(sum(value.get_method() == "POST" for value in captured), 1)

    def test_unknown_field_attempt_recovers_original_sold_value_without_fresh_price_rewrite(self):
        self.save_assignment()
        self.after_write = mock.Mock(side_effect=TimeoutError("fixture lost response"))
        with self.assertRaises(TimeoutError):
            self.publish(self.field_payload(), "Field Technician")
        self.preflight.return_value["I1"]["UnitPrice"] = 200
        recovered = self.publisher.run(self.sessions["Field Technician"], self.row()["id"])
        self.assertEqual(recovered["document"]["TotalAmt"], 189)
        self.assertEqual(len(self.writes), 1)

    def test_different_job_cannot_adopt_the_original_invoice_for_an_update(self):
        self.save_assignment()
        self.publish(self.field_payload(), "Field Technician")
        other = str(uuid.uuid4())
        self.save_assignment(self.assignment(serviceCallID=other))
        draft = self.field_payload(serviceCallID=other, operation="update")
        draft["document"].update(Id="D1", SyncToken="0", sparse=True)
        self.expect("review_required", lambda: self.publish(draft, "Field Technician"))
        self.expect("job_changed", lambda: self.publish(draft))
        self.assertEqual(len(self.writes), 1)

    def test_field_update_retains_job_and_existing_unpaid_invoice_guards(self):
        self.save_assignment()
        self.publish(self.field_payload(), "Field Technician")
        draft = self.field_payload(operation="update")
        draft["document"].update(Id="D1", SyncToken="0", sparse=True)
        draft["document"]["Line"][0]["Amount"] = 378
        draft["document"]["Line"][0]["SalesItemLineDetail"]["Qty"] = 2
        self.publish(draft, "Field Technician")
        self.assertEqual(len(self.writes), 2)
        self.assertEqual(self.writes[1][1]["Line"][0]["Amount"], 378)

    def test_http_assigned_field_publish_recover_list_and_unsent_cancellation(self):
        route = "/api/billing-publications"
        with self.http() as request:
            self.assertEqual(request("/api/job-billing-assignments", self.assignment(), "Dispatcher")[0], 200)
            self.assertEqual(request("/api/job-billing-assignments?" + urllib.parse.urlencode(self.job_scope()), role="Field Technician")[0], 200)
            status, result = request(route, self.field_payload(), "Field Technician")
            self.assertEqual(status, 200, result)
            identifier = result["publication"]["id"]
            self.assertEqual(request(route + "/" + identifier + "/recover", {}, "Field Technician")[0], 200)
            self.assertEqual(request(route + "/" + identifier + "/cancel", {}, "Field Technician")[0], 409)
            query = {key: self.payload()[key] for key in ("companyID", "realmID", "environment", "documentType", "localDocumentID")}
            status, listed = request(route + "?" + urllib.parse.urlencode(query), role="Field Technician")
            self.assertEqual(status, 200, listed)
            self.assertEqual([value["id"] for value in listed["publications"]], [identifier])
            unsent = self.publisher.reserve(self.admin, self.payload(localDocumentID=str(uuid.uuid4())))
            self.assertEqual(request(route + "/" + unsent["id"] + "/cancel", {})[0], 200)
            self.assertEqual(len(self.writes), 1)

    def test_http_exact_office_draft_approval_and_revocation(self):
        route = "/api/billing-publications"
        with self.http() as request:
            payload = {"proposal": self.payload(), "technicianEmail": self.email("Field Technician")}
            self.assertEqual(request(route + "/approve", payload, "Field Technician")[0], 403)
            status, grant = request(route + "/approve", payload)
            self.assertEqual(status, 200, grant)
            self.assertEqual(request(route + "/draft-grants/" + grant["id"] + "/revoke", {})[0], 200)
            self.assertEqual(request(route, self.payload(), "Field Technician")[0], 403)
            request(route + "/approve", payload)
            self.assertEqual(request(route, self.payload(), "Field Technician")[0], 200)

    def test_http_rejects_bad_session_duplicate_keys_nonfinite_json_and_unsafe_actions(self):
        route = "/api/billing-publications"
        with self.http() as request:
            self.assertEqual(request(route, self.payload(), token="not-an-app-session")[0], 401)
            self.assertEqual(request("/api/job-billing-assignments", self.assignment(), "Field Technician")[0], 403)
            for raw in (b'{"companyID":"first","companyID":"second"}', b'{"x":NaN}', b'{"x":{"y":1,"y":2}}', b'[]', b'"x"', b'\xff'):
                self.assertEqual(request(route, raw=raw)[0], 400)
            for path, body in ((route + "?extra=1", self.payload()), (route + "/", self.payload()),
                               (route + "/" + str(uuid.uuid4()) + "/send", {}), (route + "/approve", {"proposal": self.payload()}),
                               (route + "?companyID=x&companyID=y", None), (route + "/anything", None)):
                self.assertIn(request(path, body)[0], (400, 404))
            self.assertFalse(self.writes)

    def test_http_storage_failure_is_sanitized_and_does_not_emit_saved_draft(self):
        with self.http() as request, mock.patch.object(backend, "encrypt_catalog_payload", side_effect=RuntimeError("private-secret-diagnostic")):
            status, body = request("/api/billing-publications", self.payload())
            self.assertEqual(status, 503)
            self.assertNotIn("private-secret", json.dumps(body))
            self.assertNotIn("Repair", json.dumps(body))

    def test_office_list_pages_are_exact_document_scoped_and_preserve_all_attempts(self):
        query = {key: self.payload()[key] for key in ("companyID", "realmID", "environment", "documentType", "localDocumentID")}
        for _ in range(52):
            row = self.publisher.reserve(self.admin, self.payload())
            self.publisher.cancel(self.admin, row["id"])
        first = self.publisher.list_for_document(self.admin, query)
        second = self.publisher.list_for_document(self.admin, {**query, "cursor": first["nextCursor"]})
        self.assertEqual(len(first["publications"]), 50)
        self.assertEqual(len(second["publications"]), 2)
        self.assertIsNone(second["nextCursor"])
        self.assertEqual(len({row["id"] for row in first["publications"] + second["publications"]}), 52)
        self.expect("invalid_query", lambda: self.publisher.list_for_document(self.admin, {**query, "localDocumentID": str(uuid.uuid4()), "cursor": first["nextCursor"]}))

    def test_field_list_does_not_expose_another_jobs_publication(self):
        self.publish()
        query = {key: self.payload()[key] for key in ("companyID", "realmID", "environment", "documentType", "localDocumentID")}
        self.assertEqual(self.publisher.list_for_document(self.sessions["Field Technician"], query)["publications"], [])
        self.expect("access_denied", lambda: self.publisher.list_for_document(self.sessions["Standard"], query))
        self.expect("access_denied", lambda: self.publisher.list_for_document(self.sessions["Dispatcher"], query))

    def test_field_pagination_can_pass_inaccessible_history_without_disclosing_ids(self):
        self.save_assignment()
        original = self.field_payload()
        row = self.publisher.reserve(self.sessions["Field Technician"], original)
        self.publisher.cancel(self.sessions["Field Technician"], row["id"])
        for _ in range(51):
            other = self.publisher.reserve(self.admin, self.payload())
            self.publisher.cancel(self.admin, other["id"])
        query = {key: self.payload()[key] for key in ("companyID", "realmID", "environment", "documentType", "localDocumentID")}
        first = self.publisher.list_for_document(self.sessions["Field Technician"], query)
        self.assertEqual(first["publications"], [])
        self.assertIsNotNone(first["nextCursor"])
        self.assertNotIn(other["id"], json.dumps(first))
        second = self.publisher.list_for_document(self.sessions["Field Technician"], {**query, "cursor": first["nextCursor"]})
        self.assertEqual([value["id"] for value in second["publications"]], [row["id"]])
        self.assertIsNone(second["nextCursor"])

    def test_uuid_case_cannot_make_revocation_or_cancellation_silently_do_nothing(self):
        grant = self.publisher.approve_draft(self.admin, self.payload(), self.email("Field Technician"))
        self.publisher.revoke_draft(self.admin, grant.upper())
        self.expect("review_required", lambda: self.publish(role="Field Technician"))
        row = self.publisher.reserve(self.admin, self.payload())
        result = self.publisher.cancel(self.admin, row["id"].upper())
        self.assertEqual(result["publication"]["state"], "cancelled")
        self.expect("cancelled", lambda: self.publisher.run(self.admin, row["id"].upper()))

    def test_uppercase_direct_claim_consumes_exactly_one_durable_permit(self):
        row = self.publisher.reserve(self.admin, self.payload())
        self.publisher.claim(self.admin, row["id"].upper())
        self.assertEqual(self.row()["state"], "sending")
        self.expect("publication_pending", lambda: self.publisher.claim(self.admin, row["id"]))

    def test_encrypted_assignment_and_bound_document_survive_database_backup(self):
        self.save_assignment()
        self.publish(self.field_payload(), "Field Technician")
        restored_path = backend.DATA_ROOT / "restored.sqlite3"
        with backend.db() as original, sqlite3.connect(restored_path) as destination:
            original.backup(destination)
        with mock.patch.object(backend, "DB_PATH", restored_path):
            result = self.jobs.read(self.sessions["Field Technician"], self.job_scope())
            self.assertTrue(result["assignment"]["usable"])
            recovered = self.publisher.run(self.sessions["Field Technician"], self.row()["id"])
            self.assertEqual(recovered["publication"]["state"], "confirmed")
        self.assertEqual(len(self.writes), 1)


if __name__ == "__main__":
    unittest.main()
