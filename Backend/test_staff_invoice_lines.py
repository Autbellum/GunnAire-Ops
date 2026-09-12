from __future__ import annotations

import copy
import io
import json
import unittest
import urllib.parse
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
from unittest import mock

from Backend import gunnaire_backend as backend, staff_invoice_lines as lines
from Backend import test_staff_workspace_commands as command_http
from Backend import test_staff_workspace_selections as fixtures


class StaffInvoiceLinesHTTPTests(unittest.TestCase):
    Fixture = command_http.StaffWorkspaceCommandsHTTPTests
    setUp, tearDown, request = Fixture.setUp, Fixture.tearDown, Fixture.request
    workspace, binding_payload, bind = Fixture.workspace, Fixture.binding_payload, Fixture.bind
    prepare, enroll, change = Fixture.prepare, Fixture.enroll, Fixture.change
    requested, advance, accepted = Fixture.requested, Fixture.advance, Fixture.accepted
    root, participant_name, participant_hash = Fixture.root, Fixture.participant_name, Fixture.participant_hash
    write_source, post, deliver = Fixture.write_source, Fixture.post, Fixture.deliver
    seed_content = Fixture.seed_content

    def body(self, kind="new", **changes):
        invoice = fixtures.row(self.records, "invoice")
        item = fixtures.row(self.records, "item")
        value = lambda key, tag, nullable=False: lines.atom(item["fields"], key, tag, nullable)
        line = dict(kind=kind, itemID=str(uuid.uuid4()), itemRevision=0, itemType="Service",
                    name="Synthetic capacitor replacement", description="Parts and labor", sku=None,
                    unitPrice=123.375, quantity=2, isTaxable=False,
                    equipmentID=fixtures.row(self.records, "equipment")["id"])
        if kind == "catalog":
            line.update(itemID=item["id"], itemRevision=item["revision"], itemType=value("itemTypeRawValue", "text"),
                        name=value("name", "text"), description=value("itemDescription", "text", True),
                        sku=value("sku", "text", True), unitPrice=value("unitPrice", "number"), isTaxable=value("isTaxable", "flag"))
        result = dict(schema=lines.SCHEMA, **self.scope, commandID=str(uuid.uuid4()),
                    selectionID=self.payload["operationID"], sourceSequence=self.receipt["sourceSequence"],
                    contentSHA256=self.receipt["contentSHA256"], invoiceID=invoice["id"],
                    invoiceRevision=invoice["revision"], customerID=fixtures.row(self.records, "customer")["id"],
                    jobID=fixtures.row(self.records, "job")["id"], line=line, reason="Authorized office review required")
        result.update(changes)
        return result

    def submit(self, body, role="Field Technician", suffix=""):
        return self.request(token=self.tokens[role], method="POST", payload=body,
                            path=self.content_path + "/invoice-line-requests" + suffix)

    def review(self, command_id=None, role="Admin", query=None, suffix=""):
        return self.request(token=self.tokens[role], path="/api/workspace/invoice-line-requests" +
                            ("/" + command_id if command_id else "") + suffix + "?" +
                            urllib.parse.urlencode(self.scope if query is None else query))

    def test_new_item_request_is_recorded_not_applied_or_published(self):
        self.seed_content()
        body = self.body()
        status, receipt = self.submit(body)
        self.assertEqual(status, 200, receipt)
        self.assertEqual(receipt["request"], body)
        self.assertEqual(receipt["lineSubtotal"], "246.75")
        self.assertEqual(receipt["state"], "recorded")
        self.assertIs(receipt["officeReviewRequired"], True)
        self.assertIs(receipt["qboPublished"], False)
        self.assertNotIn("baseInvoice", receipt)
        self.assertNotIn("purchaseCost", json.dumps(receipt))
        status, review = self.review(body["commandID"])
        self.assertEqual(status, 200, review)
        self.assertEqual(review["receipt"], receipt)
        self.assertEqual(review["baseInvoice"], fixtures.row(self.records, "invoice"))
        self.assertIs(review["sourceUnchanged"], True)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT sequence FROM staff_workspace_source_heads").fetchone()[0], 1)
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_invoice_line_requests").fetchone()[0], 1)
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_workspace_source_records WHERE record_id=?", (body["line"]["itemID"],)).fetchone()[0], 0)

    def test_catalog_request_preserves_original_fractional_price(self):
        self.seed_content()
        body = self.body("catalog")
        status, receipt = self.submit(body)
        self.assertEqual(status, 200, receipt)
        self.assertEqual(receipt["request"]["line"]["unitPrice"], 123.375)
        self.assertEqual(receipt["lineSubtotal"], "246.75")
        status, review = self.review(body["commandID"])
        self.assertEqual(status, 200, review)
        self.assertEqual(review["baseItem"], fixtures.row(self.records, "item"))

    def refresh(self, record):
        self.write_source([record], self.sequence, record["revision"])
        record["revision"] += 1
        self.sequence += 1
        self.payload.update(operationID=str(uuid.uuid4()), expectedSourceSequence=self.sequence)
        self.assertEqual(self.post()[0], 200)
        self.content_path = self.endpoint + "/" + self.payload["operationID"] + "/content"
        status, self.receipt = self.deliver()
        self.assertEqual(status, 200, self.receipt)

    def count(self):
        with backend.db() as connection:
            return connection.execute("SELECT COUNT(*) FROM staff_invoice_line_requests").fetchone()[0]

    def test_concurrent_identical_submissions_have_one_identity_and_receipt(self):
        self.seed_content()
        body = self.body()
        with ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(lambda _: self.submit(body), range(3)))
        self.assertEqual(results[0][0], 200, results)
        self.assertTrue(all(value == results[0] for value in results))
        self.assertEqual(self.count(), 1)
        backend.initialize_database()
        self.assertEqual(self.submit(body), results[0])
        altered = copy.deepcopy(body)
        altered["line"]["quantity"] += 1
        status, result = self.submit(altered)
        self.assertEqual((status, result["code"]), (409, "request_changed"))

    def test_lost_receipt_is_recoverable_after_office_changes_original_invoice(self):
        self.seed_content()
        body = self.body()
        original = self.submit(body)
        self.assertEqual(original[0], 200, original)
        invoice = copy.deepcopy(fixtures.row(self.records, "invoice"))
        fixtures.set_value(invoice, "notes", "Office note after staff submission")
        self.write_source([invoice], 1, 1)
        backend.initialize_database()
        self.assertEqual(self.submit(body), original)
        status, result = self.submit(self.body())
        self.assertEqual((status, result["code"]), (409, "source_changed"))
        status, review = self.review(body["commandID"])
        self.assertEqual(status, 200, review)
        self.assertFalse(review["sourceUnchanged"])
        self.assertEqual(review["baseInvoice"], fixtures.row(self.records, "invoice"))
        self.assertEqual(review["currentInvoice"]["revision"], 2)

    def test_revocation_blocks_staff_replay_but_retains_owner_recovery(self):
        self.seed_content()
        body = self.body()
        self.assertEqual(self.submit(body)[0], 200)
        self.advance(self.share, "revoke")
        self.assertEqual(self.submit(body)[0], 403)
        self.assertEqual(self.review(body["commandID"])[0], 200)
        self.assertEqual(self.count(), 1)

    def test_inactive_staff_and_expired_session_cannot_replay(self):
        self.seed_content()
        body = self.body()
        status, original = self.submit(body)
        self.assertEqual(status, 200, original)
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0 WHERE email=?", (original["actorEmail"],))
        self.assertIn(self.submit(body)[0], (401, 403))
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=1 WHERE email=?", (original["actorEmail"],))
            connection.execute("UPDATE auth_sessions SET expires_at='2000-01-01T00:00:00+00:00' WHERE email=?", (original["actorEmail"],))
        self.assertIn(self.submit(body)[0], (401, 403))
        self.assertEqual(self.count(), 1)

    def test_author_and_owner_role_boundaries_apply_on_every_endpoint(self):
        self.seed_content()
        body = self.body()
        for role in ("Admin", "Accounting", "Dispatcher", "Standard"):
            self.assertEqual(self.submit(body, role=role)[0], 403 if role == "Admin" else 404, role)
        self.assertEqual(self.submit(body)[0], 200)
        for role in ("Field Technician", "Accounting", "Dispatcher", "Standard"):
            self.assertEqual(self.review(body["commandID"], role=role)[0], 403, role)
            self.assertEqual(self.review(role=role)[0], 403, role)
        self.assertEqual(self.review(str(uuid.uuid4()))[0], 404)
        self.assertEqual(self.count(), 1)

    def test_accounting_can_request_its_own_shared_invoice(self):
        self.seed_content(role="Accounting")
        body = self.body("catalog")
        self.assertEqual(self.submit(body, role="Accounting")[0], 200)
        self.assertEqual(self.submit(body)[0], 404)  # Do not disclose another staff member's share.

    def test_admin_can_request_only_under_its_own_share(self):
        self.seed_content(role="Admin")
        self.assertEqual(self.submit(self.body(), role="Admin")[0], 200)

    def test_dispatcher_share_cannot_turn_estimate_access_into_invoice_writes(self):
        self.seed_content(role="Dispatcher")
        self.assertEqual(self.submit(self.body(), role="Dispatcher")[0], 403)
        self.assertEqual(self.count(), 0)

    def test_wrong_tenant_replica_environment_selection_and_digest_fail(self):
        self.seed_content()
        original = self.body()
        for key, value in (("companyID", str(uuid.uuid4())), ("replicaID", str(uuid.uuid4())),
                           ("environment", "production"), ("selectionID", str(uuid.uuid4())),
                           ("contentSHA256", "b" * 64), ("sourceSequence", 2), ("invoiceRevision", 2),
                           ("invoiceID", str(uuid.uuid4())), ("customerID", str(uuid.uuid4())), ("jobID", None)):
            with self.subTest(key=key):
                body = dict(original, **{key: value})
                status, result = self.submit(body)
                self.assertIn(status, (400, 403, 404, 409), result)
        for key in ("companyID", "replicaID"):
            self.assertIn(self.review(query=dict(self.scope, **{key: str(uuid.uuid4())}))[0], (403, 404, 409))
        self.assertEqual(self.count(), 0)

    def test_catalog_changes_and_unavailable_equipment_cannot_be_forged(self):
        self.seed_content()
        body = self.body("catalog")
        for key, value in (("unitPrice", 1), ("itemID", str(uuid.uuid4())), ("itemRevision", 2),
                           ("itemType", "Inventory"), ("isTaxable", True), ("name", "Changed name"),
                           ("description", "Changed description"), ("sku", "Changed SKU"), ("equipmentID", str(uuid.uuid4()))):
            changed = copy.deepcopy(body)
            changed["line"][key] = value
            status, result = self.submit(changed)
            self.assertEqual(status, 409, (key, result))
        self.assertEqual(self.count(), 0)

    def test_new_item_identity_is_reserved_once_across_concurrent_requests(self):
        self.seed_content()
        first = self.body()
        second = copy.deepcopy(first)
        second["commandID"] = str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(self.submit, (first, second)))
        self.assertEqual(sorted(r[0] for r in results), [200, 409], results)
        self.assertEqual(next(r[1]["code"] for r in results if r[0] == 409), "item_identity_exists")
        self.assertEqual(self.count(), 1)
        existing = self.body()
        existing["line"]["itemID"] = fixtures.row(self.records, "item")["id"]
        self.assertEqual(self.submit(existing)[1]["code"], "item_identity_exists")

    def test_shared_catalog_blank_optional_text_is_preserved_not_normalized(self):
        self.seed_content()
        item = fixtures.row(self.records, "item")
        fixtures.set_value(item, "itemDescription", "  ")
        fixtures.set_value(item, "sku", "")
        self.refresh(item)
        status, receipt = self.submit(self.body("catalog"))
        self.assertEqual(status, 200, receipt)
        self.assertEqual(receipt["request"]["line"]["description"], "  ")
        self.assertEqual(receipt["request"]["line"]["sku"], "")

    def test_paid_and_finalized_invoices_require_office_correction(self):
        self.seed_content()
        invoice = fixtures.row(self.records, "invoice")
        for status, finalized in (("paid", None), ("unpaid", 810687500)):
            fixtures.set_value(invoice, "status", status)
            fixtures.set_value(invoice, "finalizedAt", finalized)
            self.refresh(invoice)
            code, result = self.submit(self.body())
            self.assertEqual((code, result["code"]), (409, "invoice_locked"))
        self.assertEqual(self.count(), 0)

    def test_quantity_precision_type_bounds_and_unknown_fields_fail(self):
        self.seed_content()
        original = self.body()
        for key, value in (("quantity", 0), ("quantity", -1), ("quantity", True), ("quantity", "2"),
                           ("quantity", 0.000001), ("quantity", 1_000_000), ("unitPrice", -1),
                           ("unitPrice", True), ("unitPrice", 100_000_000_000), ("itemRevision", True),
                           ("itemType", "Inventory"), ("isTaxable", 1), ("name", " "), ("description", " bad "),
                           ("equipmentID", "not-an-id"), ("purchaseCost", 10)):
            with self.subTest(key=key, value=value):
                body = copy.deepcopy(original)
                body["line"][key] = value
                self.assertEqual(self.submit(body)[0], 400)
        for key, value in (("invoiceRevision", True), ("reason", ""), ("actorEmail", "owner@example.invalid"), ("qboPublished", True)):
            self.assertEqual(self.submit(dict(original, **{key: value}))[0], 400)
        self.assertEqual(self.count(), 0)

    def test_decimal_half_up_zero_price_and_group_do_not_fabricate_totals(self):
        self.seed_content()
        for price, quantity, expected in ((1.005, 1, "1.01"), (0, 2, "0.00"), (-0.0, 2, "0.00"), (0.00001, 0.00001, "0.00")):
            body = self.body()
            body["line"].update(unitPrice=price, quantity=quantity)
            status, result = self.submit(body)
            self.assertEqual(status, 200, result)
            self.assertEqual(result["lineSubtotal"], expected)
        body["line"].update(kind="catalog", itemRevision=1, itemType="Group", unitPrice=0)
        self.assertIsNone(lines.validate(body))  # Request estimate is unknown until office expands members.

    def test_encryption_failure_and_audit_failure_leave_no_partial_request(self):
        self.seed_content()
        body = self.body()
        for boundary in ("encrypt_catalog_payload", "record_audit_event"):
            with mock.patch.object(backend, boundary, side_effect=RuntimeError("synthetic unavailable")):
                self.assertEqual(self.submit(body)[0], 503)
            self.assertEqual(self.count(), 0)
        self.assertEqual(self.submit(body)[0], 200)

    def test_encrypted_original_is_retained_and_corruption_never_becomes_new_work(self):
        self.seed_content()
        body = self.body("catalog")
        body["reason"] = "PRIVATE-REQUEST-REASON-888"
        self.assertEqual(self.submit(body)[0], 200)
        with backend.db() as connection:
            encrypted = connection.execute("SELECT ciphertext FROM staff_invoice_line_requests").fetchone()[0]
        self.assertNotIn(body["reason"], encrypted)
        original = json.loads(backend.decrypt_catalog_payload(encrypted))
        mutations = [lambda x: x["receipt"].update(state="applied"),
                     lambda x: x["receipt"].update(qboPublished=True),
                     lambda x: x["receipt"].update(actorEmail="foreign@example.invalid"),
                     lambda x: x["receipt"].update(createdAt="wrong"),
                     lambda x: x["baseInvoice"].update(revision=True),
                     lambda x: x["baseInvoice"]["fields"].update(serviceCallID={"null": {}}),
                     lambda x: x["baseInvoice"]["fields"].update(notes={"text": {"_0": "Changed base"}}),
                     lambda x: x["baseItem"]["fields"].update(unitPrice={"number": {"_0": 1}})]
        for mutate in mutations:
            changed = copy.deepcopy(original)
            mutate(changed)
            damaged = backend.encrypt_catalog_payload(json.dumps(changed))
            with backend.db() as connection:
                connection.execute("UPDATE staff_invoice_line_requests SET ciphertext=?", (damaged,))
            self.assertEqual(self.submit(body)[0], 503)
            self.assertEqual(self.review(body["commandID"])[0], 503)
            self.assertEqual(self.review()[0], 503)
            with backend.db() as connection:
                self.assertEqual(connection.execute("SELECT ciphertext FROM staff_invoice_line_requests").fetchone()[0], damaged)

    def test_owner_list_uses_bounded_keyset_pages_and_never_returns_private_bodies(self):
        self.seed_content()
        ids = []
        for _ in range(52):
            body = self.body()
            self.assertEqual(self.submit(body)[0], 200)
            ids.append(body["commandID"])
        status, first = self.review()
        self.assertEqual(status, 200, first)
        self.assertEqual(first["commandIDs"], sorted(ids)[:50])
        self.assertEqual(first["nextCursor"], sorted(ids)[49])
        status, second = self.review(query=dict(self.scope, after=first["nextCursor"]))
        self.assertEqual(status, 200, second)
        self.assertEqual(second["commandIDs"], sorted(ids)[50:])
        self.assertIsNone(second["nextCursor"])
        self.assertNotIn("baseInvoice", first)
        self.assertEqual(self.review(query=dict(self.scope, after="wrong"))[0], 400)

    def test_capacity_preserves_prior_receipts_and_original_queue(self):
        self.seed_content()
        first = self.body("catalog")
        original = self.submit(first)
        self.assertEqual(original[0], 200, original)
        for _ in range(127):
            self.assertEqual(self.submit(self.body("catalog"))[0], 200)
        status, result = self.submit(self.body("catalog"))
        self.assertEqual((status, result["code"]), (409, "request_capacity"))
        self.assertEqual(self.submit(first), original)
        self.assertEqual(self.count(), 128)

    def test_routes_reject_extra_segments_queries_and_oversized_body(self):
        self.seed_content()
        body = self.body()
        for suffix in ("/", "/extra", "?extra=1"):
            self.assertIn(self.submit(body, suffix=suffix)[0], (400, 404))
        for suffix in ("/", "/extra/extra"):
            self.assertIn(self.review(suffix=suffix)[0], (400, 404))
        self.assertEqual(self.review(query=dict(self.scope, after=""))[0], 400)
        self.assertEqual(self.review(body["commandID"], query=dict(self.scope, after=str(uuid.uuid4())))[0], 400)
        self.assertEqual(self.submit(dict(body, reason="x" * 17000))[0], 400)
        self.assertEqual(self.request(token=self.tokens["Admin"], path="/api/workspace/invoice-line-requests?" +
                                     urllib.parse.urlencode(self.scope) + "&companyID=" + self.company)[0], 400)
        self.assertEqual(self.count(), 0)

    def test_review_http_log_redacts_document_and_workspace_identifiers(self):
        self.seed_content()
        body = self.body()
        self.assertEqual(self.submit(body)[0], 200)
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(self.review(body["commandID"])[0], 200)
        log = output.getvalue()
        self.assertNotIn(body["commandID"], log)
        self.assertNotIn(self.company, log)
        self.assertIn("/api/workspace/invoice-line-requests/[redacted]", log)

    def test_archived_and_unapproved_items_remain_history_not_new_work(self):
        self.seed_content()
        item = fixtures.row(self.records, "item")
        for status in ("archived", "needs_review"):
            fixtures.set_value(item, "pricebookReviewStatusRawValue", status)
            self.refresh(item)
            code, result = self.submit(self.body("catalog"))
            self.assertEqual((code, result["code"]), (409, "item_changed"))
        self.assertEqual(self.count(), 0)

    def test_catalog_advance_keeps_original_price_and_exposes_review_conflict(self):
        self.seed_content()
        body = self.body("catalog")
        original = self.submit(body)
        self.assertEqual(original[0], 200)
        item = copy.deepcopy(fixtures.row(self.records, "item"))
        fixtures.set_value(item, "unitPrice", 150)
        self.write_source([item], 1, 1)
        self.assertEqual(self.submit(body), original)
        status, result = self.review(body["commandID"])
        self.assertEqual(status, 200, result)
        self.assertTrue(result["invoiceUnchanged"])
        self.assertFalse(result["itemUnchanged"])
        self.assertFalse(result["sourceUnchanged"])
        self.assertEqual(result["baseItem"]["fields"]["unitPrice"]["number"]["_0"], 123.375)
        self.assertEqual(result["currentItem"]["fields"]["unitPrice"]["number"]["_0"], 150)

    def test_missing_content_does_not_accept_request_or_discard_its_identity(self):
        self.seed_content()
        body = self.body()
        with backend.db() as connection:
            connection.execute("DELETE FROM staff_workspace_projections WHERE selection_id=?", (body["selectionID"],))
        status, result = self.submit(body)
        self.assertEqual((status, result["code"]), (404, "content_not_prepared"))
        self.assertEqual(self.count(), 0)
        self.assertEqual(self.deliver()[0], 200)
        self.assertEqual(self.submit(body)[0], 200)

    def test_damaged_source_base_cannot_be_recorded_under_original_projection(self):
        self.seed_content()
        body = self.body()
        with backend.db() as connection:
            row = connection.execute("SELECT * FROM staff_workspace_source_records WHERE kind='invoice'").fetchone()
            original = json.loads(backend.decrypt_catalog_payload(row["ciphertext"]))
            fixtures.set_value(original, "notes", "Corrupt same revision")
            connection.execute("UPDATE staff_workspace_source_records SET ciphertext=? WHERE kind='invoice'",
                               (backend.encrypt_catalog_payload(json.dumps(original)),))
        self.assertEqual(self.submit(body)[0], 503)
        self.assertEqual(self.count(), 0)

    def test_no_session_or_static_backend_token_cannot_submit_or_review(self):
        self.seed_content()
        with mock.patch.multiple(backend, AUTH_MODE="api-token", API_TOKEN="synthetic-static-token"):
            self.assertEqual(self.request(token="synthetic-static-token", method="POST", payload=self.body(),
                                         path=self.content_path + "/invoice-line-requests")[0], 403)
            self.assertEqual(self.request(token="synthetic-static-token", path="/api/workspace/invoice-line-requests?" +
                                         urllib.parse.urlencode(self.scope))[0], 403)
        self.assertEqual(self.request(method="POST", payload=self.body(), path=self.content_path + "/invoice-line-requests")[0], 401)
        self.assertEqual(self.count(), 0)


if __name__ == "__main__":
    unittest.main()
