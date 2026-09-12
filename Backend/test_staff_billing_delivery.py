from __future__ import annotations

import copy
import json
from pathlib import Path
import unittest
import urllib.parse
import uuid
from concurrent.futures import ThreadPoolExecutor
from unittest import mock

from Backend import gunnaire_backend as backend, cloudkit_staff_shares as shares
from Backend import staff_workspace_selection as selection, staff_workspace_contract as contract
from Backend import staff_billing_projection as billing, staff_billing_delivery as delivery
from Backend import test_staff_workspace_selections as fixtures

row, set_value = fixtures.row, fixtures.set_value
COMPANY = "a1000000-0000-4000-8000-000000000001"
REPLICA = "a1000000-0000-4000-8000-000000000002"


def metadata(role="Field Technician", company=COMPANY, replica=REPLICA):
    return dict(companyID=company, environment="development", replicaID=replica,
                membershipID="a1000000-0000-4000-8000-000000000003", memberRevision="a" * 64,
                shareRevision=4, projectionPolicy=shares.POLICIES[role], memberRole=role, sourceSequence=1)


def line(item, **changes):
    return dict(catalogItemID=item["id"].upper(), name="Original sold valve", itemTypeRawValue="Service",
                quickBooksItemID="SOLD-VALVE", unitPrice=25, pricebookUnitPrice=25, purchaseCost=19.375,
                isTaxable=True, quantity=2.5, catalogUpdatedAt=810687500, **changes)


def sale(records, lines=None, kind="invoice", discount=None, tax=0):
    if lines is None:
        lines = [line(row(records, "item"))]
    snapshot = dict(version=1, lines=lines)
    gross = sum(sum(m["line"]["unitPrice"] * m["line"].get("quantity", 1) for m in item["bundle"]["members"])
                if item.get("bundle") else round(item["unitPrice"] * item.get("quantity", 1), 2) for item in lines)
    deduction = 0
    if discount:
        snapshot["documentDiscount"] = discount
        deduction = round(gross * discount["value"] / 100, 2) if discount["kind"] == "percentage" else discount["value"]
    set_value(row(records, kind), "catalogSnapshotJSON", json.dumps(snapshot))
    set_value(row(records, kind), "amount", round(gross - deduction + tax, 2))
    set_value(row(records, kind), "salesTaxAmount", tax)
    return records


def project(records, role="Field Technician"):
    graph = selection.Graph(records)
    return billing.prepare(graph, graph.index(role, fixtures.EMAIL), metadata(role, records[0]["companyID"], records[0]["replicaID"]))


def rich_records(company=COMPANY, replica=REPLICA):
    records = fixtures.fixture_records(company, replica)
    part = copy.deepcopy(row(records, "item"))
    part["id"] = "a2000000-0000-4000-8000-000000000001"
    records.append(part)
    root = line(row(records, "item"))
    root.update(itemTypeRawValue="Group", unitPrice=0, pricebookUnitPrice=0, quantity=3, quickBooksItemID="SOLD-GROUP")
    members = []
    for index, quantity in enumerate((6, 3)):
        leaf = line(part)
        leaf.update(quantity=quantity, quickBooksItemID="MEMBER")
        leaf["servicedEquipment"] = dict(equipmentID=row(records, "equipment")["id"].upper(), name="Original system", serialNumber="ORIGINAL-123")
        members.append(dict(id="A3000000-0000-4000-8000-00000000000" + str(index + 1), line=leaf, tracksInventory=True))
    root["bundle"] = dict(scope=dict(companyID=company.upper(), realmID="ORIGINAL-REALM", environment="sandbox"), printGroupedItems=False, members=members)
    discount = dict(kind="percentage", value=10, grossSubtotalAtAuthorization=225, reason="Service plan discount", authorizedByEmail="historical.owner@example.invalid", authorizedAt=810687500)
    sale(records, [root], discount=discount, tax=3.15)
    assembly = dict(assemblyItemID=row(records, "item")["id"].upper(), name="Original repair package", revision=3,
        presentation="flat_rate", components=[dict(itemID=part["id"].upper(), name="Included valve", quantity=2, purchaseCost=3.125, tracksInventory=True)])
    sold = line(row(records, "item"), assembly=assembly)
    sale(records, [sold], kind="estimate")
    return records


def interop():
    records = rich_records()
    return dict(records=[dict(version=1, kind=r["kind"], id=r["id"].upper(), fields=r["fields"]) for r in records],
                projections={role: project(records, role) for role in shares.POLICIES})


class StaffBillingProjectionTests(unittest.TestCase):
    def test_all_native_billing_fields_have_one_explicit_disposition_for_all_five_roles(self):
        records = fixtures.fixture_records(COMPANY, REPLICA)
        billing.coverage()
        for role, kinds in (("Admin", {"invoice", "estimate"}), ("Accounting", {"invoice"}), ("Dispatcher", {"estimate"}),
                            ("Field Technician", {"invoice"}), ("Standard", set())):
            result = project(records, role)
            self.assertEqual({doc["kind"] for doc in result["documents"]}, kinds)
            for doc in result["documents"]:
                self.assertFalse(set(doc["fields"]) & set(doc["unavailableFields"]))
                self.assertEqual(set(doc["fields"]) | set(doc["unavailableFields"]) | {"catalogSnapshotJSON"}, set(contract.SPECS[doc["kind"]]))
                self.assertEqual(doc["catalog"], {"notRecorded": {}})
                for name, value in doc["fields"].items():
                    self.assertEqual(value, row(records, doc["kind"])["fields"][name])

    def test_cost_and_provider_disclosure_distinguishes_restricted_missing_and_zero(self):
        for cost in (None, 0, 19.375):
            records = fixtures.fixture_records(COMPANY, REPLICA)
            sold = line(row(records, "item")); sold["purchaseCost"] = cost
            sale(records, [sold])
            for role in ("Admin", "Accounting", "Field Technician"):
                result = next(d for d in project(records, role)["documents"] if d["kind"] == "invoice")
                projected = result["catalog"]["saved"]["_0"]["lines"][0]
                self.assertEqual(projected["purchaseCost"], billing.disclosure(cost, role != "Field Technician"))
                self.assertEqual(projected["quickBooksItemID"], billing.disclosure("SOLD-VALVE", role != "Field Technician"))

    def test_hidden_cost_changes_do_not_change_any_disclosed_byte_or_content_hash(self):
        records = rich_records()
        original = contract.canonical(project(records))
        for cost in (None, 0, 1, 99999):
            value = json.loads(selection.Graph(records).value("invoice", row(records, "invoice")["id"], "catalogSnapshotJSON"))
            value["lines"][0]["purchaseCost"] = cost
            for member in value["lines"][0]["bundle"]["members"]:
                member["line"]["purchaseCost"] = cost
            set_value(row(records, "invoice"), "catalogSnapshotJSON", json.dumps(value))
            self.assertEqual(contract.canonical(project(records)), original)

    def test_bundle_order_ids_already_extended_quantities_discount_and_tax_remain_exact(self):
        result = project(rich_records())["documents"][0]
        saved = result["catalog"]["saved"]["_0"]
        root = saved["lines"][0]
        self.assertEqual(root["quantity"], 3)
        self.assertEqual(root["extendedAmount"], 225)
        self.assertEqual([m["line"]["quantity"] for m in root["bundle"]["members"]], [6, 3])
        self.assertEqual(len({m["id"] for m in root["bundle"]["members"]}), 2)
        self.assertEqual(root["bundle"]["scope"], {"restricted": {}})
        self.assertEqual(saved["discount"]["grossSubtotalAtAuthorization"], 225)
        self.assertEqual(result["fields"]["amount"], {"number": {"_0": 205.65}})
        self.assertEqual(result["fields"]["salesTaxAmount"], {"number": {"_0": 3.15}})
        self.assertEqual(root["bundle"]["members"][0]["line"]["servicedEquipment"]["serialNumber"], "ORIGINAL-123")

    def test_assembly_physical_parts_retained_and_private_costs_restricted(self):
        records = rich_records()
        dispatcher = project(records, "Dispatcher")["documents"][0]["catalog"]["saved"]["_0"]["lines"][0]["assembly"]
        self.assertEqual(dispatcher["revision"], 3)
        self.assertEqual(dispatcher["components"][0]["quantity"], 2)
        self.assertEqual(dispatcher["components"][0]["purchaseCost"], {"restricted": {}})
        owner = project(records, "Admin")["documents"][0]["catalog"]["saved"]["_0"]["lines"][0]["assembly"]
        self.assertEqual(owner["components"][0]["purchaseCost"], {"recorded": {"_0": 3.125}})

    def test_legacy_absent_defaults_are_supported_but_explicit_null_bool_and_precision_are_not(self):
        records = fixtures.fixture_records(COMPANY, REPLICA)
        sold = line(row(records, "item")); del sold["quantity"]; del sold["pricebookUnitPrice"]
        sale(records, [sold])
        value = project(records)["documents"][0]["catalog"]["saved"]["_0"]["lines"][0]
        self.assertEqual((value["quantity"], value["pricebookUnitPrice"]), (1, 25))
        for name, invalid in (("quantity", None), ("quantity", True), ("quantity", 0), ("quantity", .000001),
                              ("pricebookUnitPrice", None), ("unitPrice", -1), ("unitPrice", 1.000001), ("isTaxable", 1)):
            changed = copy.deepcopy(sold); changed[name] = invalid
            set_value(row(records, "invoice"), "catalogSnapshotJSON", json.dumps([changed]))
            with self.subTest(name=name, value=invalid), self.assertRaises(shares.AttemptError):
                project(records)

    def test_malformed_or_foreign_hidden_invoice_blocks_even_a_role_without_invoices(self):
        for change in (lambda x: x.update(newSecret="must not be passed"),
                       lambda x: x["lines"][0]["bundle"]["scope"].update(companyID=str(uuid.uuid4())),
                       lambda x: x["lines"][0]["bundle"]["scope"].update(realmID="../invalid"),
                       lambda x: x["lines"][0]["bundle"]["members"][0]["line"].update(catalogItemID=str(uuid.uuid4())),
                       lambda x: x["lines"][0]["bundle"]["members"][0]["line"]["servicedEquipment"].update(equipmentID=str(uuid.uuid4())),
                       lambda x: x["documentDiscount"].update(grossSubtotalAtAuthorization=224)):
            records = rich_records()
            value = json.loads(selection.Graph(records).value("invoice", row(records, "invoice")["id"], "catalogSnapshotJSON"))
            change(value)
            set_value(row(records, "invoice"), "catalogSnapshotJSON", json.dumps(value))
            for role in ("Field Technician", "Standard", "Dispatcher"):
                with self.assertRaises(shares.AttemptError):
                    project(records, role)

    def test_mismatched_amount_and_unauthorized_adjustment_require_original_evidence_review(self):
        records = sale(fixtures.fixture_records(COMPANY, REPLICA))
        set_value(row(records, "invoice"), "amount", 50)
        with self.assertRaises(shares.AttemptError): project(records)
        sold = line(row(records, "item")); sold["unitPrice"] = 20
        sale(records, [sold])
        with self.assertRaises(shares.AttemptError): project(records)
        sold.update(priceAdjustmentReason="Approved adjustment", priceAdjustmentAuthorizedByEmail="owner@example.invalid", priceAdjustmentAuthorizedAt=810687500)
        sale(records, [sold])
        result = project(records)["documents"][0]["catalog"]["saved"]["_0"]["lines"][0]
        self.assertEqual((result["unitPrice"], result["pricebookUnitPrice"], result["extendedAmount"]), (20, 25, 50))

    def test_duplicate_json_unknown_nested_keys_and_excess_depth_never_disclose_raw_payload(self):
        records = fixtures.fixture_records(COMPANY, REPLICA)
        for raw in ('{"version":1,"version":1,"lines":[]}', '[' * 18 + '0' + ']' * 18,
                    '{"version":true,"lines":[]}', '{"version":1,"lines":[],"providerSecret":"secret"}', '[NaN]'):
            set_value(row(records, "invoice"), "catalogSnapshotJSON", raw)
            with self.assertRaises(shares.AttemptError): project(records)

    def test_same_customer_unassigned_invoice_does_not_gain_content(self):
        records = rich_records()
        other = fixtures.clone(row(records, "invoice")); set_value(other, "serviceCallID", None)
        records.append(other)
        self.assertEqual(len(project(records)["documents"]), 1)
        self.assertEqual(len(project(records, "Accounting")["documents"]), 2)

    def test_committed_interop_vector_matches_current_server_projection(self):
        path = Path(__file__).resolve().parents[1] / "GunnAire OpsTests" / "StaffBillingServerInterop.json"
        self.assertEqual(json.loads(path.read_text()), interop())

    def test_tax_addresses_preserve_original_business_scope_and_require_complete_us_addresses(self):
        records = sale(fixtures.fixture_records(COMPANY, REPLICA))
        graph = selection.Graph(records); doc = row(records, "invoice")
        value = json.loads(graph.value("invoice", doc["id"], "catalogSnapshotJSON"))
        scope = dict(customerID=graph.value("invoice", doc["id"], "customer").upper())
        location, address = graph.value("invoice", doc["id"], "serviceLocationID"), graph.value("invoice", doc["id"], "siteAddress")
        if location: scope["serviceLocationID"] = location.upper()
        if address and address.strip(): scope["siteAddress"] = address.strip()
        us = dict(Line1="123 Test Street", City="Richmond", CountrySubDivisionCode="VA", PostalCode="23220", Country="US")
        value["taxAddresses"] = dict(version=1, scope=scope, service=us, origin=dict(us), reviewedAt=810687500)
        set_value(doc, "catalogSnapshotJSON", json.dumps(value))
        projected = project(records)["documents"][0]["catalog"]["saved"]["_0"]
        self.assertEqual(projected["taxAddresses"], value["taxAddresses"])
        for change in (lambda x: x["scope"].update(customerID=str(uuid.uuid4())),
                       lambda x: x["scope"].update(siteAddress="Another property"),
                       lambda x: x["service"].update(PostalCode="invalid"),
                       lambda x: x["origin"].update(CountrySubDivisionCode="ZZ"),
                       lambda x: x.update(privateSecret="unexpected")):
            changed = copy.deepcopy(value); change(changed["taxAddresses"])
            set_value(doc, "catalogSnapshotJSON", json.dumps(changed))
            with self.assertRaises(shares.AttemptError): project(records)

    def test_legacy_line_array_and_fixed_discount_keep_exact_totals(self):
        records = sale(fixtures.fixture_records(COMPANY, REPLICA))
        sold = line(row(records, "item"))
        set_value(row(records, "invoice"), "catalogSnapshotJSON", json.dumps([sold]))
        self.assertEqual(project(records)["documents"][0]["catalog"]["saved"]["_0"]["lines"][0]["extendedAmount"], 62.5)
        discount = dict(kind="fixed_amount", value=12.5, grossSubtotalAtAuthorization=62.5, reason="Approved credit", authorizedByEmail="owner@example.invalid", authorizedAt=810687500)
        sale(records, [sold], discount=discount)
        self.assertEqual(project(records)["documents"][0]["fields"]["amount"], {"number": {"_0": 50.0}})

    def test_repeated_bundle_member_ids_recursive_bundles_and_duplicate_assembly_parts_fail(self):
        for change in (lambda v: v["lines"][0]["bundle"]["members"][1].update(id=v["lines"][0]["bundle"]["members"][0]["id"]),
                       lambda v: v["lines"][0]["bundle"]["members"][0]["line"].update(bundle=copy.deepcopy(v["lines"][0]["bundle"]))):
            records = rich_records()
            value = json.loads(selection.Graph(records).value("invoice", row(records, "invoice")["id"], "catalogSnapshotJSON"))
            change(value); set_value(row(records, "invoice"), "catalogSnapshotJSON", json.dumps(value))
            with self.assertRaises(shares.AttemptError): project(records)
        records = rich_records()
        value = json.loads(selection.Graph(records).value("estimate", row(records, "estimate")["id"], "catalogSnapshotJSON"))
        components = value["lines"][0]["assembly"]["components"]; components.append(copy.deepcopy(components[0]))
        set_value(row(records, "estimate"), "catalogSnapshotJSON", json.dumps(value))
        with self.assertRaises(shares.AttemptError): project(records)


class StaffBillingDeliveryHTTPTests(unittest.TestCase):
    Fixture = fixtures.FullStaffSelectionHTTPTests
    setUp, tearDown, request = Fixture.setUp, Fixture.tearDown, Fixture.request
    workspace, binding_payload, bind = Fixture.workspace, Fixture.binding_payload, Fixture.bind
    prepare, enroll, change = Fixture.prepare, Fixture.enroll, Fixture.change
    requested, advance, accepted = Fixture.requested, Fixture.advance, Fixture.accepted
    root, participant_name, participant_hash = Fixture.root, Fixture.participant_name, Fixture.participant_hash
    write_source, post = Fixture.write_source, Fixture.post

    def seed(self, role="Field Technician", extra=0):
        self.prepare()
        self.scope = dict(companyID=self.company, environment="development", replicaID=self.workspace()["bindings"][0]["replicaID"])
        self.records = rich_records(self.company, self.scope["replicaID"])
        for _ in range(extra): self.records.append(fixtures.clone(row(self.records, "invoice")))
        self.sequence = 0
        for start in range(0, len(self.records), 100):
            self.write_source(self.records[start:start + 100], self.sequence); self.sequence += 1
        self.share = self.accepted(role)
        self.endpoint = self.root + "/" + self.share["id"] + "/full-selections"
        self.payload = dict(**self.scope, operationID=str(uuid.uuid4()), expectedSourceSequence=self.sequence,
                            expectedShareRevision=self.share["revision"], sourceSchemaDigest=contract.SCHEMA_DIGEST)
        status, result = self.post(); self.assertEqual(status, 200, result)
        self.billing_path = self.endpoint + "/" + self.payload["operationID"] + "/billing"
        return self.deliver()

    def deliver(self, role="Admin", payload=None):
        return self.request(token=self.tokens[role], path=self.billing_path, method="POST", payload=payload or dict(**self.scope, contentSchema=billing.SCHEMA))

    def get_billing(self, documents=False, role="Admin", query=None):
        path = self.billing_path + ("/documents" if documents else "") + "?" + urllib.parse.urlencode(query or self.scope)
        return self.request(token=self.tokens[role], path=path)

    def test_actual_http_delivers_only_typed_role_billing_content_with_explicit_incomplete_workspace(self):
        status, receipt = self.seed(); self.assertEqual(status, 200, receipt)
        status, page = self.get_billing(True); self.assertEqual(status, 200, page)
        self.assertEqual(page["contentSHA256"], receipt["contentSHA256"])
        self.assertEqual(page["coverage"], ["estimate", "invoice"])
        self.assertEqual(len(page["sourceCoverage"]), 32)
        self.assertFalse(page["operationalWorkspaceReady"])
        self.assertTrue(page["fieldProjectionRequired"] and page["localCloudKitProofRequired"])
        self.assertEqual([d["kind"] for d in page["projection"]["documents"]], ["invoice"])
        self.assertEqual(page["recordIndex"][0]["id"], row(self.records, "invoice")["id"])
        self.assertNotIn("ORIGINAL-REALM", json.dumps(page))
        self.assertNotIn("19.375", json.dumps(page))
        self.assertNotIn("catalogSnapshotJSON", json.dumps(page))
        with backend.db() as connection:
            saved = connection.execute("SELECT ciphertext FROM staff_billing_projections").fetchone()[0]
            self.assertNotIn("Original sold valve", saved)

    def test_target_staff_and_other_nonadmins_cannot_fetch_owner_preparation(self):
        self.assertEqual(self.seed()[0], 200)
        for role in self.tokens:
            if role != "Admin":
                self.assertEqual(self.deliver(role)[0], 403)
                self.assertEqual(self.get_billing(role=role)[0], 403)
                self.assertEqual(self.get_billing(True, role)[0], 403)

    def test_exact_lost_reply_recovery_restart_and_concurrent_replay_retain_one_original(self):
        original = self.seed(); self.assertEqual(original[0], 200)
        backend.initialize_database()
        self.assertEqual(self.deliver(), original)
        self.assertEqual(self.get_billing(), original)
        with ThreadPoolExecutor(max_workers=3) as pool:
            self.assertTrue(all(result == original for result in pool.map(lambda _: self.deliver(), range(3))))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_billing_projections").fetchone()[0], 1)

    def test_source_advance_preserves_receipt_but_denies_all_old_content_pages(self):
        _, original = self.seed()
        job = copy.deepcopy(row(self.records, "job")); set_value(job, "assignedTechnician", None)
        self.write_source([job], self.sequence, 1)
        status, recovered = self.deliver(); self.assertEqual(status, 200, recovered)
        self.assertEqual(recovered["contentSHA256"], original["contentSHA256"])
        self.assertFalse(recovered["sourceCurrent"])
        self.assertEqual(self.get_billing(True)[1]["code"], "source_changed")

    def test_rollback_role_mismatch_and_revocation_cannot_recover_data(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE cloudkit_staff_shares SET projection_policy='admin-operations-v1'")
        self.assertEqual(self.get_billing(True)[0], 403)
        self.assertEqual(self.deliver()[0], 403)
        with backend.db() as connection:
            connection.execute("UPDATE cloudkit_staff_shares SET projection_policy=?", (shares.POLICIES["Field Technician"],))
            connection.execute("DELETE FROM staff_workspace_source_heads")
        self.assertEqual(self.get_billing(True)[0], 503)

    def test_corruption_requires_recovery_without_rebuilding_original_content(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE staff_billing_projections SET ciphertext='corrupt'")
        self.assertEqual(self.deliver()[0], 503)
        self.assertEqual(self.get_billing(True)[0], 503)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT ciphertext FROM staff_billing_projections").fetchone()[0], "corrupt")

    def test_pages_are_bounded_ordered_and_bound_to_one_immutable_projection(self):
        status, receipt = self.seed(extra=102); self.assertEqual(status, 200, receipt)
        documents, indexes, query = [], [], dict(self.scope)
        while True:
            status, page = self.get_billing(True, query=query); self.assertEqual(status, 200, page)
            self.assertLessEqual(len(page["projection"]["documents"]), delivery.PAGE_COUNT)
            self.assertLessEqual(len(contract.wire(page).encode()), delivery.PAGE_BYTES)
            self.assertEqual(page["contentSHA256"], receipt["contentSHA256"])
            documents.extend(page["projection"]["documents"]); indexes.extend(page["recordIndex"])
            if page["nextCursor"] is None: break
            query["after"] = page["nextCursor"]
        self.assertEqual(len(documents), 103)
        self.assertEqual([delivery.key(d) for d in documents], sorted({delivery.key(d) for d in documents}))
        full = dict(page["projection"], documents=documents)
        self.assertEqual(delivery.digest(full), receipt["contentSHA256"])
        self.assertEqual(len(indexes), 103)

    def test_unknown_schema_fields_scope_cursor_and_duplicate_query_are_rejected(self):
        self.assertEqual(self.seed()[0], 200)
        for key, value in (("contentSchema", "unknown"), ("role", "Admin"), ("companyID", str(uuid.uuid4())), ("environment", "production")):
            self.assertNotEqual(self.deliver(payload=dict(**self.scope, contentSchema=billing.SCHEMA) | {key: value})[0], 200)
        self.assertEqual(self.get_billing(True, query=dict(self.scope, after="invoice:" + str(uuid.uuid4())))[0], 400)
        path = self.billing_path + "?" + urllib.parse.urlencode(self.scope) + "&companyID=" + self.company
        self.assertEqual(self.request(token=self.tokens["Admin"], path=path)[0], 400)
        self.assertEqual(self.request(token=self.tokens["Admin"], path=self.billing_path + "/unknown")[0], 404)

    def new_selection(self):
        self.payload = dict(self.payload, operationID=str(uuid.uuid4()), expectedSourceSequence=self.sequence)
        status, result = self.post(); self.assertEqual(status, 200, result)
        self.billing_path = self.endpoint + "/" + self.payload["operationID"] + "/billing"

    def test_encryption_failure_rolls_back_new_content_and_keeps_prior_projection(self):
        self.assertEqual(self.seed()[0], 200)
        self.new_selection()
        with mock.patch.object(backend, "encrypt_catalog_payload", side_effect=RuntimeError("fixture storage failure")):
            self.assertEqual(self.deliver()[0], 503)
        self.assertEqual(self.get_billing()[0], 404)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_billing_projections").fetchone()[0], 1)
        self.assertEqual(self.deliver()[0], 200)

    def test_revoked_share_keeps_original_but_refuses_further_reading(self):
        self.assertEqual(self.seed()[0], 200)
        self.advance(self.share, "revoke")
        self.assertEqual(self.deliver()[0], 403)
        self.assertEqual(self.get_billing()[0], 403)
        self.assertEqual(self.get_billing(True)[0], 403)

    def test_deactivated_member_cannot_continue_access_through_existing_preparation(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0 WHERE email=?", (fixtures.EMAIL,))
        self.assertEqual(self.deliver()[0], 403)
        self.assertEqual(self.get_billing(True)[0], 403)

    def test_session_revoked_between_http_and_transaction_cannot_read_or_prepare(self):
        self.assertEqual(self.seed()[0], 200)
        before = backend.GunnAireBackendHandler.require_application_session
        def revoke(handler):
            result = before(handler)
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at=? WHERE email='admin@gunnaire.com'", (backend.utc_now(),))
            return result
        with mock.patch.object(backend.GunnAireBackendHandler, "require_application_session", revoke):
            self.assertEqual(self.get_billing(True)[0], 403)
        self.assertEqual(self.deliver()[0], 401)

    def test_another_admin_cannot_adopt_the_original_creator_content(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Admin' WHERE email='dispatcher@gunnaire.com'")
        self.assertEqual(self.get_billing(True, role="Dispatcher")[0], 404)
        self.assertEqual(self.deliver(role="Dispatcher")[0], 404)

    def test_byte_bounded_pages_split_before_the_count_limit_without_dropping_documents(self):
        self.assertEqual(self.seed(extra=2)[0], 200)
        with mock.patch.object(delivery, "PAGE_BYTES", 10000):
            status, first = self.get_billing(True); self.assertEqual(status, 200, first)
            self.assertLess(len(first["projection"]["documents"]), 3)
            self.assertIsNotNone(first["nextCursor"])
            self.assertLessEqual(len(contract.wire(first).encode()), 10000)
            with mock.patch.object(delivery, "PAGE_BYTES", 1000):
                self.assertEqual(self.get_billing(True)[1]["code"], "source_capacity")

    def test_bad_hidden_billing_evidence_does_not_create_partial_content(self):
        self.assertEqual(self.seed(role="Standard")[0], 200)
        invoice = copy.deepcopy(row(self.records, "invoice"))
        set_value(invoice, "catalogSnapshotJSON", '{"version":1,"lines":[],"secret":"do not echo"}')
        self.write_source([invoice], self.sequence, 1); self.sequence += 1
        self.new_selection()
        status, result = self.deliver()
        self.assertEqual(result["code"], "billing_evidence_pending")
        self.assertNotIn("do not echo", json.dumps(result))
        self.assertEqual(self.get_billing()[0], 404)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_billing_projections").fetchone()[0], 1)

    def test_decrypted_projection_digest_mismatch_requires_storage_recovery(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE staff_billing_projections SET content_sha256=?", ("0" * 64,))
        self.assertEqual(self.deliver()[0], 503)
        self.assertEqual(self.get_billing(True)[0], 503)


if __name__ == "__main__":
    unittest.main()
