from __future__ import annotations

import copy
import http.client
import json
import unittest
import urllib.parse
import uuid
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from unittest import mock

from Backend import gunnaire_backend as backend, staff_owner_invoice_applications as applications
from Backend import staff_invoice_lines as lines, staff_billing_projection as billing
from Backend import test_staff_invoice_lines as request_tests
from Backend import test_staff_workspace_selections as fixtures


class StaffOwnerInvoiceApplicationTests(unittest.TestCase):
    Fixture = request_tests.StaffInvoiceLinesHTTPTests
    setUp, tearDown, request = Fixture.setUp, Fixture.tearDown, Fixture.request
    workspace, binding_payload, bind = Fixture.workspace, Fixture.binding_payload, Fixture.bind
    prepare, enroll, change = Fixture.prepare, Fixture.enroll, Fixture.change
    requested, advance, accepted = Fixture.requested, Fixture.advance, Fixture.accepted
    root, participant_name, participant_hash = Fixture.root, Fixture.participant_name, Fixture.participant_hash
    write_source, post, deliver = Fixture.write_source, Fixture.post, Fixture.deliver
    seed_content, body, submit, refresh = Fixture.seed_content, Fixture.body, Fixture.submit, Fixture.refresh

    def seed_proposal(self, kind="new"):
        self.seed_content()
        package_kind = kind if kind in ("catalog_group", "catalog_assembly") else None
        part = None
        assembly_parts = []
        if package_kind:
            kind = "catalog"
            root = fixtures.row(self.records, "item")
            part = copy.deepcopy(root); part["id"] = str(uuid.uuid4())
            for key, value in dict(name="Included synthetic part", unitPrice=10, quickBooksID="SYNTHETIC-PART").items():
                fixtures.set_value(part, key, value)
            self.write_source([part], self.sequence, 0); self.sequence += 1; self.records.append(part)
            if package_kind == "catalog_group":
                for key, value in dict(itemTypeRawValue="Group", unitPrice=0, quickBooksID="SYNTHETIC-GROUP").items():
                    fixtures.set_value(root, key, value)
            else:
                extra = copy.deepcopy(part); extra["id"] = str(uuid.uuid4())
                fixtures.set_value(extra, "name", "Second synthetic part")
                fixtures.set_value(extra, "quickBooksID", "SYNTHETIC-SECOND")
                self.write_source([extra], self.sequence, 0); self.sequence += 1; self.records.append(extra)
                assembly_parts = [(part, 2), (extra, 3)]
                definition = dict(schemaVersion=1, revision=1, presentation="itemized",
                                  components=[dict(itemID=item["id"].upper(), quantity=quantity) for item, quantity in assembly_parts])
                fixtures.set_value(root, "flatRateAssemblyJSON", json.dumps(definition))
            self.refresh(root)
        request = self.body(kind)
        status, self.staff_receipt = self.submit(request)
        self.assertEqual(status, 200, self.staff_receipt)
        invoice = copy.deepcopy(fixtures.row(self.records, "invoice"))
        proposed = copy.deepcopy(invoice)
        dependencies = [copy.deepcopy(r) for r in self.records if r["kind"] in ("customer", "job", "location", "equipment", "item")]
        line = request["line"]
        new_item = None
        now = applications.lines.owner_edits.instant(self.staff_receipt["createdAt"]).timestamp() - 978307200
        if kind == "new":
            new_item = dict(invoice, kind="item", id=line["itemID"], fields={})
            for key, spec in applications.contract.SPECS["item"].items():
                value = None if spec["nullable"] else {"text": "", "number": 0, "date": now, "integer": 0, "flag": False}.get(spec["type"])
                fixtures.set_value(new_item, key, value)
            for key, value in dict(name=line["name"], itemTypeRawValue=line["itemType"], unitPrice=line["unitPrice"],
                    itemDescription=line["description"], sku=line["sku"], isTaxable=line["isTaxable"],
                    quickBooksSyncStatus="pending", pricebookReviewStatusRawValue="approved",
                    pricebookReviewedByEmail="admin@gunnaire.com", pricebookReviewedAt=now,
                    pricebookCreatedByEmail=self.staff_receipt["actorEmail"]).items():
                fixtures.set_value(new_item, key, value)
        raw = applications.atom(invoice["fields"], "catalogSnapshotJSON")
        snapshot = json.loads(raw) if raw else []
        rows = snapshot if isinstance(snapshot, list) else snapshot["lines"]
        added = dict(catalogItemID=line["itemID"].upper(), name=line["name"], itemTypeRawValue=line["itemType"],
                     unitPrice=line["unitPrice"], pricebookUnitPrice=line["unitPrice"], isTaxable=line["isTaxable"],
                     quantity=line["quantity"], catalogUpdatedAt=now, description=line["description"], sku=line["sku"])
        if line["equipmentID"]:
            added["servicedEquipment"] = dict(equipmentID=line["equipmentID"].upper(), name="Synthetic serviced system")
        existing = next((r for r in rows if r["catalogItemID"].lower() == line["itemID"]), None)
        if package_kind == "catalog_assembly":
            # Preserve the earlier flat-rate root, adding only this request's components.
            assembly = dict(assemblyItemID=line["itemID"].upper(), name=line["name"], revision=1, presentation="itemized",
                components=[dict(itemID=item["id"].upper(), name=lines.atom(item["fields"], "name", "text"),
                                 quantity=quantity, tracksInventory=False) for item, quantity in assembly_parts])
            for item, quantity in assembly_parts:
                component = copy.deepcopy(added)
                component.update(catalogItemID=item["id"].upper(), name=lines.atom(item["fields"], "name", "text"),
                                 quantity=quantity * line["quantity"], unitPrice=10, pricebookUnitPrice=10,
                                 quickBooksItemID=lines.atom(item["fields"], "quickBooksID", "text", True), assembly=copy.deepcopy(assembly))
                rows.append(component)
        elif existing is None:
            rows.append(added)
        else:
            added["quantity"] += existing.get("quantity", 1)
            rows[rows.index(existing)] = added
        if package_kind == "catalog_group":
            added["quickBooksItemID"] = "SYNTHETIC-GROUP"
            member = dict(added, catalogItemID=part["id"].upper(), itemTypeRawValue="Service", name="Included synthetic part",
                          quickBooksItemID="SYNTHETIC-PART", quantity=2 * added["quantity"], unitPrice=10, pricebookUnitPrice=10)
            added["bundle"] = dict(scope=dict(companyID=self.company.upper(), realmID="SYNTHETIC-REALM", environment="sandbox"), printGroupedItems=True,
                                   members=[dict(id=str(uuid.uuid4()).upper(), line=member, tracksInventory=False)])
        graph = applications.ProposalGraph(dependencies + [proposed] + ([new_item] if new_item else []))
        catalog = billing.Catalog(graph, proposed)
        validated = [catalog.line(r) for r in rows]
        gross = sum((Decimal(str(r["extendedAmount"])) for r in validated), Decimal(0))
        deduction = Decimal(0)
        if isinstance(snapshot, dict) and snapshot.get("documentDiscount"):
            discount = snapshot["documentDiscount"]
            discount.update(grossSubtotalAtAuthorization=float(gross), authorizedByEmail="admin@gunnaire.com", authorizedAt=now)
            deduction = billing.cents(gross * Decimal(str(discount["value"])) / 100) if discount["kind"] == "percentage" else Decimal(str(discount["value"]))
        taxable = any(leaf["isTaxable"] for root in validated for leaf in
                      ([member["line"] for member in root["bundle"]["members"]] if "bundle" in root else [root]))
        values = dict(catalogSnapshotJSON=json.dumps(snapshot), lineItemSummary="Office-reviewed invoice lines", amount=float(gross - deduction),
            salesTaxAmount=0, taxCalculationStatusRawValue="pending_quickbooks" if taxable else "not_applicable", taxCalculatedAt=None,
            quickBooksSyncStatus="balance_needs_refresh" if applications.atom(invoice["fields"], "quickBooksID") else "pending",
            quickBooksSyncDetail="Review the updated invoice before QBO publication", customerSignedAt=None, customerSignatureName=None, customerSignatureImageBase64=None)
        for key, value in values.items():
            fixtures.set_value(proposed, key, value)
        return dict(schema=applications.SCHEMA, **self.scope, commandID=request["commandID"], operationID=str(uuid.uuid4()),
                    ownerStoreID=str(uuid.uuid4()), request=request, expectedInvoice=invoice, invoiceFields=proposed["fields"],
                    newItemFields=new_item["fields"] if new_item else None, dependencies=dependencies, reviewed=True, reason="Approve reviewed field repair lines")

    def invoke(self, proposal, action="prepare", role="Admin", suffix=""):
        payload = proposal if action == "prepare" else {key: proposal[key] for key in applications.CONFIRM.split()}
        return self.request(token=self.tokens[role], method="POST", payload=payload,
            path="/api/workspace/invoice-applications/" + proposal["commandID"] + "/" + action + suffix)

    def alter_snapshot(self, proposal, change):
        invoice = dict(proposal["expectedInvoice"], fields=proposal["invoiceFields"])
        snapshot = json.loads(applications.atom(invoice["fields"], "catalogSnapshotJSON"))
        rows = snapshot if isinstance(snapshot, list) else snapshot["lines"]
        change(rows)
        records = proposal["dependencies"] + [invoice]
        if proposal["newItemFields"] is not None:
            records.append(dict(invoice, kind="item", id=proposal["request"]["line"]["itemID"], revision=1, fields=proposal["newItemFields"]))
        catalog = billing.Catalog(applications.ProposalGraph(records), invoice)
        validated = [catalog.line(r) for r in rows]
        gross = sum((Decimal(str(r["extendedAmount"])) for r in validated), Decimal(0))
        deduction = Decimal(0)
        if isinstance(snapshot, dict) and snapshot.get("documentDiscount"):
            discount = snapshot["documentDiscount"]; discount["grossSubtotalAtAuthorization"] = float(gross)
            deduction = billing.cents(gross * Decimal(str(discount["value"])) / 100) if discount["kind"] == "percentage" else Decimal(str(discount["value"]))
        taxable = any(leaf["isTaxable"] for root in validated for leaf in
                      ([member["line"] for member in root["bundle"]["members"]] if "bundle" in root else [root]))
        for key, value in dict(catalogSnapshotJSON=json.dumps(snapshot), amount=float(gross - deduction),
                              taxCalculationStatusRawValue="pending_quickbooks" if taxable else "not_applicable").items():
            fixtures.set_value(invoice, key, value)

    def read_application(self, proposal, role="Admin", query=None):
        return self.request(token=self.tokens[role], path="/api/workspace/invoice-applications/" + proposal["commandID"] + "?" + urllib.parse.urlencode(query or self.scope))

    def publish(self, proposal, invoice=True, item=True):
        changes = []
        if invoice:
            changes.append(dict(kind="invoice", id=proposal["request"]["invoiceID"], action="upsert",
                expectedRevision=proposal["expectedInvoice"]["revision"], fields=proposal["invoiceFields"]))
        if item and proposal["newItemFields"] is not None:
            changes.append(dict(kind="item", id=proposal["request"]["line"]["itemID"], action="upsert", expectedRevision=0, fields=proposal["newItemFields"]))
        with backend.db() as connection:
            sequence = connection.execute("SELECT sequence FROM staff_workspace_source_heads").fetchone()[0]
        result = self.request(token=self.tokens["Admin"], method="POST", path="/api/workspace/full-records", payload=dict(
            **self.scope, schema=applications.contract.SCHEMA_VERSION, schemaDigest=applications.contract.SCHEMA_DIGEST,
            operationID=str(uuid.uuid4()), expectedSequence=sequence, changes=changes))
        self.assertEqual(result[0], 200, result)

    def test_prepare_does_not_write_invoice_item_or_qbo_and_is_recoverable(self):
        proposal = self.seed_proposal()
        self.assertEqual(self.read_application(proposal)[1], dict(schema=applications.SCHEMA, application=None))
        first = self.invoke(proposal)
        self.assertEqual(first[0], 200, first)
        self.assertEqual(first[1]["state"], "prepared")
        self.assertFalse(first[1]["qboPublished"])
        backend.initialize_database()
        self.assertEqual(self.invoke(proposal), first)
        recovered = self.read_application(proposal)
        self.assertEqual(recovered[0], 200, recovered)
        self.assertEqual(recovered[1]["application"], dict(proposal=proposal, receipt=first[1]))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT sequence FROM staff_workspace_source_heads").fetchone()[0], 1)
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_workspace_source_records WHERE record_id=?", (proposal["request"]["line"]["itemID"],)).fetchone()[0], 0)

    def test_confirmation_requires_both_exact_source_records_then_replays(self):
        proposal = self.seed_proposal()
        self.assertEqual(self.invoke(proposal, "confirm")[0], 409)
        self.assertEqual(self.invoke(proposal)[0], 200)
        self.assertEqual(self.invoke(proposal, "confirm")[0], 409)
        self.publish(proposal, item=False)
        self.assertEqual(self.invoke(proposal, "confirm")[0], 409)
        self.publish(proposal, invoice=False)
        result = self.invoke(proposal, "confirm")
        self.assertEqual(result[0], 200, result)
        self.assertEqual(result[1]["state"], "published")
        self.assertFalse(result[1]["qboPublished"])
        self.assertEqual(self.invoke(proposal, "confirm"), result)
        self.assertEqual(self.invoke(proposal), result)

    def test_catalog_application_does_not_create_another_item(self):
        proposal = self.seed_proposal("catalog")
        self.assertIsNone(proposal["newItemFields"])
        result = self.invoke(proposal)
        self.assertEqual(result[0], 200, result)
        self.publish(proposal)
        self.assertEqual(self.invoke(proposal, "confirm")[0], 200)

    def test_every_route_requires_current_owner_account(self):
        proposal = self.seed_proposal()
        self.assertEqual(self.invoke(proposal)[0], 200)
        for role in ("Field Technician", "Accounting", "Dispatcher", "Standard"):
            self.assertEqual(self.invoke(proposal, role=role)[0], 403)
            self.assertEqual(self.invoke(proposal, "confirm", role=role)[0], 403)
            self.assertEqual(self.read_application(proposal, role=role)[0], 403)
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0 WHERE email='admin@gunnaire.com'")
        self.assertIn(self.invoke(proposal)[0], (401, 403))
        self.assertIn(self.read_application(proposal)[0], (401, 403))

    def test_scope_and_exact_endpoint_guards_do_not_leak_saved_proposal(self):
        proposal = self.seed_proposal()
        for key, value in (("companyID", str(uuid.uuid4())), ("replicaID", str(uuid.uuid4())), ("environment", "production")):
            changed = dict(proposal, **{key: value})
            self.assertIn(self.invoke(changed)[0], (400, 403, 404, 409))
            self.assertIn(self.read_application(proposal, query=dict(self.scope, **{key: value}))[0], (403, 404, 409))
        for suffix in ("/", "?extra=1", "/anything"):
            self.assertIn(self.invoke(proposal, suffix=suffix)[0], (400, 404))
        path = "/api/workspace/invoice-applications/" + proposal["commandID"]
        query = urllib.parse.urlencode(self.scope)
        self.assertEqual(self.request(token=self.tokens["Admin"], path=path + "?" + query + "&companyID=" + self.company)[0], 400)
        self.assertEqual(self.request(token=self.tokens["Admin"], path=path + "/?" + query)[0], 404)
        self.assertEqual(self.request(method="POST", path=path + "/prepare", payload=proposal)[0], 401)

    def test_changed_operation_device_or_original_intent_cannot_replace_claim(self):
        proposal = self.seed_proposal()
        original = self.invoke(proposal)
        self.assertEqual(original[0], 200, original)
        for key, value in (("operationID", str(uuid.uuid4())), ("ownerStoreID", str(uuid.uuid4())), ("reason", "Different approved proposal")):
            self.assertEqual(self.invoke(dict(proposal, **{key: value}))[0], 409)
        changed = copy.deepcopy(proposal); changed["request"]["reason"] = "Changed field intent"
        self.assertEqual(self.invoke(changed)[0], 409)
        self.assertEqual(self.invoke(proposal), original)

    def test_concurrent_retries_create_one_claim_and_one_preparation_audit(self):
        proposal = self.seed_proposal()
        with ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(lambda _: self.invoke(proposal), range(3)))
        self.assertEqual(results[0][0], 200, results)
        self.assertTrue(all(result == results[0] for result in results))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_owner_invoice_applications").fetchone()[0], 1)
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM audit_events WHERE action='prepare-invoice-application'").fetchone()[0], 1)

    def test_another_request_on_same_invoice_waits_for_original_claim(self):
        proposal = self.seed_proposal()
        self.assertEqual(self.invoke(proposal)[0], 200)
        other = copy.deepcopy(proposal)
        other["request"] = self.body()
        self.assertEqual(self.submit(other["request"])[0], 200)
        other.update(commandID=other["request"]["commandID"], operationID=str(uuid.uuid4()), ownerStoreID=str(uuid.uuid4()))
        atom = other["invoiceFields"]["catalogSnapshotJSON"]["text"]
        atom["_0"] = atom["_0"].replace(proposal["request"]["line"]["itemID"].upper(), other["request"]["line"]["itemID"].upper())
        status, result = self.invoke(other)
        self.assertEqual((status, result["code"]), (409, "invoice_claimed"))

    def test_boolean_review_unknown_fields_and_unsupported_model_writes_fail(self):
        proposal = self.seed_proposal()
        for value in (False, 1, "true", None):
            self.assertEqual(self.invoke(dict(proposal, reviewed=value))[0], 400)
        self.assertEqual(self.invoke(dict(proposal, extra="hidden"))[0], 400)
        for key, value in (("customer", str(uuid.uuid4())), ("status", "paid"), ("quickBooksID", "OTHER-QBO"), ("notes", "Unrelated office text")):
            changed = copy.deepcopy(proposal)
            fixtures.set_value(dict(kind="invoice", fields=changed["invoiceFields"]), key, value)
            self.assertEqual(self.invoke(changed)[0], 409, key)
        changed = copy.deepcopy(proposal); changed["expectedInvoice"]["revision"] = True
        self.assertEqual(self.invoke(changed)[0], 400)

    def test_paid_finalized_and_progress_invoices_use_correction_workflow(self):
        proposal = self.seed_proposal()
        for key, value in (("status", "paid"), ("finalizedAt", 810000000), ("projectMilestoneID", str(uuid.uuid4())), ("milestoneDraftReceiptJSON", "{}")):
            changed = copy.deepcopy(proposal)
            fixtures.set_value(changed["expectedInvoice"], key, value)
            status, result = self.invoke(changed)
            self.assertEqual((status, result["code"]), (409, "invoice_locked"), key)

    def test_tax_old_signature_and_false_qbo_success_are_rejected(self):
        proposal = self.seed_proposal()
        for key, value in (("salesTaxAmount", 1), ("taxCalculatedAt", 810000000), ("customerSignatureName", "Old signature"),
                           ("customerSignedAt", 810000000), ("quickBooksSyncStatus", "synced"), ("taxCalculationStatusRawValue", "calculated_by_quickbooks")):
            changed = copy.deepcopy(proposal)
            fixtures.set_value(dict(kind="invoice", fields=changed["invoiceFields"]), key, value)
            self.assertEqual(self.invoke(changed)[0], 409, key)

    def test_invalid_total_or_missing_item_cannot_be_claimed(self):
        proposal = self.seed_proposal()
        changed = copy.deepcopy(proposal)
        fixtures.set_value(dict(kind="invoice", fields=changed["invoiceFields"]), "amount", 0)
        self.assertEqual(self.invoke(changed)[0], 409)
        changed = copy.deepcopy(proposal)
        changed["dependencies"] = [r for r in changed["dependencies"] if r["kind"] != "customer"]
        self.assertEqual(self.invoke(changed)[0], 409)
        changed = copy.deepcopy(proposal); changed["dependencies"].append(changed["dependencies"][0])
        self.assertEqual(self.invoke(changed)[0], 400)

    def test_current_invoice_or_catalog_change_blocks_new_claim_and_retry(self):
        proposal = self.seed_proposal()
        changed = copy.deepcopy(fixtures.row(self.records, "item"))
        fixtures.set_value(changed, "unitPrice", 999)
        self.write_source([changed], 1, 1)
        self.assertEqual(self.invoke(proposal)[0], 409)
        # Re-review the dependency explicitly; unchanged original invoice is still approvable.
        changed["revision"] = 2
        proposal["dependencies"] = [changed if r["id"] == changed["id"] else r for r in proposal["dependencies"]]
        self.assertEqual(self.invoke(proposal)[0], 200)
        invoice = copy.deepcopy(proposal["expectedInvoice"])
        fixtures.set_value(invoice, "notes", "Another office edit")
        self.write_source([invoice], 2, 1)
        self.assertEqual(self.invoke(proposal)[0], 409)
        self.assertEqual(self.invoke(proposal, "confirm")[0], 409)
        self.assertEqual(self.read_application(proposal)[0], 200)

    def test_staff_revocation_retains_explicit_owner_review_and_original_author(self):
        proposal = self.seed_proposal()
        self.advance(self.share, "revoke")
        result = self.invoke(proposal)
        self.assertEqual(result[0], 200, result)
        recovered = self.read_application(proposal)[1]["application"]
        self.assertEqual(recovered["proposal"]["request"], proposal["request"])
        self.assertEqual(self.submit(proposal["request"])[0], 403)

    def test_new_item_must_keep_author_review_type_and_no_provider_identity(self):
        proposal = self.seed_proposal()
        for key, value in (("quickBooksID", "FORGED"), ("quickBooksSyncStatus", "synced"), ("unitPrice", 1),
                           ("pricebookCreatedByEmail", "other@example.invalid"), ("pricebookReviewedByEmail", "other@example.invalid"),
                           ("pricebookReviewStatusRawValue", "needs_review"), ("tracksInventory", True), ("pricebookReviewedAt", None),
                           ("quickBooksCatalogReceiptJSON", "{}"), ("quickBooksLastSyncedAt", 810000000), ("purchaseCost", -1)):
            changed = copy.deepcopy(proposal)
            fixtures.set_value(dict(kind="item", fields=changed["newItemFields"]), key, value)
            self.assertEqual(self.invoke(changed)[0], 409, key)

    def test_corrupt_encrypted_claim_is_retained_without_repairing_or_leaking_it(self):
        proposal = self.seed_proposal()
        self.assertEqual(self.invoke(proposal)[0], 200)
        with backend.db() as connection:
            raw = connection.execute("SELECT ciphertext FROM staff_owner_invoice_applications").fetchone()[0]
            self.assertNotIn(proposal["reason"], raw)
            saved = json.loads(backend.decrypt_catalog_payload(raw)); saved["receipt"]["qboPublished"] = True
            damaged = backend.encrypt_catalog_payload(json.dumps(saved))
            connection.execute("UPDATE staff_owner_invoice_applications SET ciphertext=?", (damaged,))
        for result in (self.invoke(proposal), self.invoke(proposal, "confirm"), self.read_application(proposal)):
            self.assertEqual(result[0], 503, result)
            self.assertNotIn(proposal["reason"], json.dumps(result))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT ciphertext FROM staff_owner_invoice_applications").fetchone()[0], damaged)

    def test_failed_claim_encryption_leaves_no_partial_application(self):
        proposal = self.seed_proposal()
        with mock.patch.object(backend, "encrypt_catalog_payload", side_effect=RuntimeError("synthetic failure")):
            self.assertEqual(self.invoke(proposal)[0], 503)
        self.assertIsNone(self.read_application(proposal)[1]["application"])
        self.assertEqual(self.invoke(proposal)[0], 200)

    def test_other_original_lines_cannot_be_removed_or_repriced(self):
        proposal = self.seed_proposal()
        target = proposal["request"]["line"]["itemID"].upper()
        for remove in (True, False):
            changed = copy.deepcopy(proposal)
            def alter(rows):
                other = next(r for r in rows if r["catalogItemID"] != target)
                if remove:
                    rows.remove(other)
                else:
                    other["unitPrice"] += 1; other["pricebookUnitPrice"] = other["unitPrice"]
            self.alter_snapshot(changed, alter)
            status, result = self.invoke(changed)
            self.assertEqual((status, result["code"]), (409, "invoice_unrelated_lines_changed"))

    def test_requested_quantity_and_equipment_cannot_be_silently_changed(self):
        proposal = self.seed_proposal()
        target = proposal["request"]["line"]["itemID"].upper()
        for field in ("quantity", "servicedEquipment"):
            changed = copy.deepcopy(proposal)
            def alter(rows):
                row = next(r for r in rows if r["catalogItemID"] == target)
                if field == "quantity": row[field] += 1
                else: row.pop(field)
            self.alter_snapshot(changed, alter)
            self.assertEqual(self.invoke(changed)[0], 409)

    def test_manual_invoice_balance_is_not_dropped_by_itemization(self):
        proposal = self.seed_proposal()
        fixtures.set_value(proposal["expectedInvoice"], "catalogSnapshotJSON", None)
        fixtures.set_value(proposal["expectedInvoice"], "amount", 100)
        status, result = self.invoke(proposal)
        self.assertEqual((status, result["code"]), (409, "invoice_manual_lines_required"))

    def test_confirmation_cannot_accept_approximate_or_later_altered_source(self):
        proposal = self.seed_proposal()
        self.assertEqual(self.invoke(proposal)[0], 200)
        changed = copy.deepcopy(proposal)
        fixtures.set_value(dict(kind="invoice", fields=changed["invoiceFields"]), "lineItemSummary", "Different reviewed content")
        self.publish(changed)
        self.assertEqual(self.invoke(proposal, "confirm")[0], 409)
        self.assertEqual(self.read_application(proposal)[1]["application"]["receipt"]["state"], "prepared")

    def test_confirmed_receipt_is_historical_and_never_applies_again(self):
        proposal = self.seed_proposal()
        self.assertEqual(self.invoke(proposal)[0], 200)
        self.publish(proposal)
        receipt = self.invoke(proposal, "confirm")
        self.assertEqual(receipt[0], 200, receipt)
        invoice = dict(proposal["expectedInvoice"], revision=2, fields=copy.deepcopy(proposal["invoiceFields"]))
        fixtures.set_value(invoice, "notes", "Later unrelated office work")
        self.write_source([invoice], 2, 2)
        self.assertEqual(self.invoke(proposal), receipt)
        self.assertEqual(self.invoke(proposal, "confirm"), receipt)

    def test_audit_failure_rolls_back_preparation_and_keeps_original_request(self):
        proposal = self.seed_proposal()
        with mock.patch.object(backend, "record_audit_event", side_effect=RuntimeError("synthetic audit failure")):
            self.assertEqual(self.invoke(proposal)[0], 503)
        self.assertIsNone(self.read_application(proposal)[1]["application"])
        self.assertEqual(self.invoke(proposal)[0], 200)

    def test_http_log_redacts_invoice_application_identity(self):
        import io
        from contextlib import redirect_stdout
        proposal = self.seed_proposal()
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(self.invoke(proposal)[0], 200)
        self.assertNotIn(proposal["commandID"], output.getvalue())
        self.assertIn("/api/workspace/invoice-applications/[redacted]", output.getvalue())

    def test_history_capacity_blocks_new_claim_but_keeps_exact_recovery(self):
        proposal = self.seed_proposal()
        with mock.patch.object(applications, "MAX_HISTORY_BYTES", 1):
            self.assertEqual(self.invoke(proposal)[0], 409)
        self.assertIsNone(self.read_application(proposal)[1]["application"])
        original = self.invoke(proposal)
        self.assertEqual(original[0], 200, original)
        with mock.patch.object(applications, "MAX_HISTORY_BYTES", 1):
            self.assertEqual(self.invoke(proposal), original)
            self.assertEqual(self.read_application(proposal)[0], 200)

    def test_counter_overflow_cannot_reserve_an_unpublishable_proposal(self):
        proposal = self.seed_proposal()
        changed = copy.deepcopy(proposal); changed["expectedInvoice"]["revision"] = 2_147_483_646
        self.assertEqual(self.invoke(changed)[0], 400)
        with backend.db() as connection:
            connection.execute("UPDATE staff_workspace_source_heads SET sequence=2147483646")
        self.assertEqual(self.invoke(proposal)[0], 400)
        self.assertIsNone(self.read_application(proposal)[1]["application"])

    def test_nested_duplicate_json_is_rejected_before_claiming(self):
        proposal = self.seed_proposal()
        changed = copy.deepcopy(proposal)
        raw = changed["invoiceFields"]["catalogSnapshotJSON"]["text"]["_0"]
        # Duplicate even an identical value; do not let JSON parsing discard it.
        marker = '"unitPrice":'
        index = raw.index(marker)
        changed["invoiceFields"]["catalogSnapshotJSON"]["text"]["_0"] = raw[:index] + '"unitPrice":0,' + raw[index:]
        self.assertEqual(self.invoke(changed)[0], 409)
        self.assertIsNone(self.read_application(proposal)[1]["application"])

    def test_oversized_request_is_rejected_by_http_body_limit(self):
        proposal = self.seed_proposal()
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        try:
            connection.putrequest("POST", "/api/workspace/invoice-applications/" + proposal["commandID"] + "/prepare")
            connection.putheader("Authorization", "Bearer " + self.tokens["Admin"])
            connection.putheader("Content-Type", "application/json")
            connection.putheader("Content-Length", str(applications.MAX_BYTES + 1))
            connection.endheaders()
            response = connection.getresponse()
            self.assertEqual(response.status, 400)  # Existing bounded-body policy rejects headers before reading.
            self.assertEqual(json.loads(response.read())["code"], "invalid_request")
        finally:
            connection.close()
        self.assertIsNone(self.read_application(proposal)[1]["application"])

    def test_static_token_cannot_prepare_confirm_or_read_owner_proposal(self):
        proposal = self.seed_proposal()
        root = "/api/workspace/invoice-applications/" + proposal["commandID"]
        with mock.patch.multiple(backend, AUTH_MODE="api-token", API_TOKEN="synthetic-static-token"):
            for action in ("prepare", "confirm"):
                self.assertEqual(self.request(token="synthetic-static-token", method="POST", path=root + "/" + action, payload=proposal)[0], 403)
            self.assertEqual(self.request(token="synthetic-static-token", path=root + "?" + urllib.parse.urlencode(self.scope))[0], 403)

    def test_existing_new_item_identity_is_not_adopted_by_a_new_claim(self):
        proposal = self.seed_proposal()
        self.publish(proposal, invoice=False)
        status, result = self.invoke(proposal)
        self.assertEqual((status, result["code"]), (409, "invoice_item_exists"))
        self.assertIsNone(self.read_application(proposal)[1]["application"])

    def test_group_proposal_uses_member_prices_not_zero_header(self):
        proposal = self.seed_proposal("catalog_group")
        self.assertIsNone(self.staff_receipt["lineSubtotal"])
        self.assertGreater(applications.atom(proposal["invoiceFields"], "amount"), 0)
        result = self.invoke(proposal)
        self.assertEqual(result[0], 200, result)
        self.publish(proposal)
        self.assertEqual(self.invoke(proposal, "confirm")[0], 200)

    def test_itemized_package_preserves_previous_root_without_double_charging(self):
        proposal = self.seed_proposal("catalog_assembly")
        before = json.loads(applications.atom(proposal["expectedInvoice"]["fields"], "catalogSnapshotJSON"))
        after = json.loads(applications.atom(proposal["invoiceFields"], "catalogSnapshotJSON"))
        old_rows = before if isinstance(before, list) else before["lines"]
        rows = after if isinstance(after, list) else after["lines"]
        root = next(r for r in old_rows if r["catalogItemID"].lower() == proposal["request"]["line"]["itemID"])
        self.assertEqual(next(r for r in rows if r["catalogItemID"] == root["catalogItemID"]), root)
        result = self.invoke(proposal)
        self.assertEqual(result[0], 200, result)
        self.publish(proposal)
        self.assertEqual(self.invoke(proposal, "confirm")[0], 200)

    def test_package_requires_all_components_one_recipe_and_exact_quantities(self):
        proposal = self.seed_proposal("catalog_assembly")
        target = proposal["request"]["line"]["itemID"].upper()
        for mutation, code in (("missing", "invoice_package_changed"), ("revision", "invoice_package_changed"),
                               ("quantity", "invoice_quantity_changed"), ("charge_root", "invoice_unrelated_lines_changed")):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(proposal)
                def alter(rows):
                    components = [r for r in rows if r.get("assembly", {}).get("assemblyItemID") == target]
                    if mutation == "missing": rows.remove(components[0])
                    elif mutation == "revision": components[0]["assembly"]["revision"] += 1
                    elif mutation == "quantity": components[0]["quantity"] += 1
                    else: next(r for r in rows if r["catalogItemID"] == target)["quantity"] += proposal["request"]["line"]["quantity"]
                self.alter_snapshot(changed, alter)
                status, result = self.invoke(changed)
                self.assertEqual((status, result["code"]), (409, code))
                self.assertIsNone(self.read_application(proposal)[1]["application"])
        self.assertEqual(self.invoke(proposal)[0], 200)

    def test_saved_receipt_cannot_replace_false_with_numeric_zero(self):
        proposal = self.seed_proposal()
        self.assertEqual(self.invoke(proposal)[0], 200)
        with backend.db() as connection:
            raw = connection.execute("SELECT ciphertext FROM staff_owner_invoice_applications").fetchone()[0]
            saved = json.loads(backend.decrypt_catalog_payload(raw))
            saved["receipt"]["qboPublished"] = 0
            damaged = backend.encrypt_catalog_payload(json.dumps(saved))
            connection.execute("UPDATE staff_owner_invoice_applications SET ciphertext=?", (damaged,))
        for result in (self.invoke(proposal), self.invoke(proposal, "confirm"), self.read_application(proposal)):
            self.assertEqual(result[0], 503, result)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT ciphertext FROM staff_owner_invoice_applications").fetchone()[0], damaged)

    def test_confirmation_encryption_or_audit_failure_preserves_prepared_recovery(self):
        proposal = self.seed_proposal()
        prepared = self.invoke(proposal)
        self.assertEqual(prepared[0], 200)
        self.publish(proposal)
        for target in ("encrypt_catalog_payload", "record_audit_event"):
            with self.subTest(target=target), mock.patch.object(backend, target, side_effect=RuntimeError("synthetic failure")):
                self.assertEqual(self.invoke(proposal, "confirm")[0], 503)
            self.assertEqual(self.read_application(proposal)[1]["application"]["receipt"], prepared[1])
        with ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(lambda _: self.invoke(proposal, "confirm"), range(3)))
        self.assertEqual(results[0][0], 200, results)
        self.assertTrue(all(result == results[0] for result in results))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM audit_events WHERE action='confirm-invoice-application'").fetchone()[0], 1)


if __name__ == "__main__":
    unittest.main()
