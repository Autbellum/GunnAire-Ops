"""Real owner HTTP claims, real publishers and synthetic provider evidence only."""
from __future__ import annotations

import copy
import json
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal, ROUND_HALF_UP
from unittest import mock

from Backend import gunnaire_backend as backend, billing_publications as billing
from Backend import catalog_publications as catalog, payment_attempts as payments
from Backend import invoice_application_fences as fences, staff_owner_invoice_applications as applications
from Backend import test_staff_owner_invoice_applications as owner_tests
from Backend import test_staff_workspace_selections as fields


class InvoiceApplicationFenceTests(unittest.TestCase):
    def setUp(self):
        self.owner = owner_tests.StaffOwnerInvoiceApplicationTests()
        self.owner.setUp()
        self.addCleanup(self.owner.tearDown)
        self.writes, self.remotes = [], {}
        self.before_write = lambda: None
        self.after_write = lambda remote: remote
        fixture = self

        class Provider:
            def __init__(self, context, authorize):
                self.authorize = authorize

            def documents(self, kind):
                self.authorize()
                return list(copy.deepcopy(fixture.remotes).values())

            def read(self, kind, identifier):
                self.authorize()
                return copy.deepcopy(fixture.remotes[identifier])

            def preflight(self, document):
                self.authorize()
                return {}

            def write(self, kind, document, request_id, before_send):
                fixture.before_write()
                before_send()
                fixture.writes.append((kind, copy.deepcopy(document), request_id))
                identifier = document.get("Id", "D1")
                total = float(billing.net_amount(document["Line"]))
                remote = dict(copy.deepcopy(document), Id=identifier,
                    SyncToken=str(int(document.get("SyncToken", "-1")) + 1),
                    TotalAmt=total, Balance=total, TxnTaxDetail={"TotalTax": 0}, CurrencyRef={"value": "USD"})
                fixture.remotes[identifier] = remote
                return fixture.after_write(copy.deepcopy(remote))

        self.publisher = billing.BillingPublisher(backend.db, Provider, backend.encrypt_catalog_payload,
            backend.decrypt_catalog_payload, backend.record_audit_event)
        self.catalog = catalog.CatalogPublisher(backend.db, mock.Mock(), backend.encrypt_catalog_payload,
            backend.decrypt_catalog_payload, backend.record_audit_event)
        self.journal = payments.PaymentAttemptJournal(backend.db, self.read_invoice, mock.Mock(), mock.Mock(),
            backend.record_audit_event, decrypt=backend.decrypt_catalog_payload)
        with backend.db() as connection:
            self.admin = connection.execute("SELECT id FROM auth_sessions WHERE token_hash=?",
                (backend.app_session_token_hash(self.owner.tokens["Admin"]),)).fetchone()[0]
            connection.execute("INSERT INTO qbo_connections VALUES (1,'SYNTHETIC-REALM','cipher','sandbox','client','grant','updated')")
            columns = [row[1] for row in connection.execute("PRAGMA table_info(qbo_accounting_config)")]
            values = dict.fromkeys(columns, "")
            values.update(realm_id="SYNTHETIC-REALM", environment="sandbox", default_income_account_ref="income")
            connection.execute("INSERT INTO qbo_accounting_config (" + ",".join(columns) + ") VALUES (" +
                ",".join("?" for _ in columns) + ")", tuple(values.values()))

    def seed(self, kind="new"):
        self.proposal = self.owner.seed_proposal(kind)
        self.company = self.owner.company
        self.invoice_id = self.proposal["request"]["invoiceID"]
        self.customer_id = self.proposal["request"]["customerID"]
        snapshot = json.loads(applications.atom(self.proposal["invoiceFields"], "catalogSnapshotJSON"))
        rows = snapshot if isinstance(snapshot, list) else snapshot["lines"]
        realms = {row["bundle"]["scope"]["realmID"] for row in rows if row.get("bundle")}
        self.assertLessEqual(len(realms), 1)
        self.realm = next(iter(realms), "SYNTHETIC-REALM")
        self.ids = {}
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET realm_id=?", (self.realm,))
            connection.execute("UPDATE qbo_accounting_config SET realm_id=?", (self.realm,))
            connection.execute("INSERT INTO customer_entity_mappings VALUES (?,?,'sandbox',?,'C1')",
                (self.company, self.realm, self.customer_id))
            for record in self.proposal["dependencies"]:
                if record["kind"] == "item":
                    self.ids[record["id"]] = applications.lines.atom(record["fields"], "quickBooksID", "text", True) or "I-" + record["id"]
            self.ids.setdefault(self.proposal["request"]["line"]["itemID"], "I-new")
            for local, provider in self.ids.items():
                if self.proposal["newItemFields"] is not None and local == self.proposal["request"]["line"]["itemID"]:
                    continue
                connection.execute("INSERT INTO catalog_entity_mappings VALUES (?,?,'sandbox',?,?)",
                    (self.company, self.realm, local, provider))
        return self.proposal

    def prepare(self):
        result = self.owner.invoke(self.proposal)
        self.assertEqual(result[0], 200, result)
        return result[1]

    def applied(self):
        self.prepare()
        self.owner.publish(self.proposal)
        result = self.owner.invoke(self.proposal, "confirm")
        self.assertEqual(result[0], 200, result)
        self.assertFalse(result[1]["qboPublished"])
        if self.proposal["newItemFields"] is not None:
            # Synthetic evidence for a separately verified catalog publication.
            # Never insert a new-item mapping before the owner source is saved.
            with backend.db() as connection:
                local = self.proposal["request"]["line"]["itemID"]
                connection.execute("INSERT INTO catalog_entity_mappings VALUES (?,?,'sandbox',?,?)",
                    (self.company, self.realm, local, self.ids[local]))
        return result[1]

    def payload(self):
        # Independent conversion of the synthetic sold snapshot. Do not use
        # the fence's financial_lines to manufacture the expected request.
        raw = json.loads(applications.atom(self.proposal["invoiceFields"], "catalogSnapshotJSON"))
        def line(value):
            provider = self.ids[value["catalogItemID"].lower()]
            quantity = value.get("quantity", 1)
            if value.get("bundle"):
                return dict(Amount=0, DetailType="GroupLineDetail", GroupLineDetail=dict(
                    GroupItemRef={"value": provider}, Quantity=quantity,
                    Line=[line(member["line"]) for member in value["bundle"]["members"]]))
            amount = (Decimal(str(value["unitPrice"])) * Decimal(str(quantity))).quantize(Decimal(".01"), rounding=ROUND_HALF_UP)
            return dict(Amount=float(amount), Description=value.get("name", "Synthetic work"), DetailType="SalesItemLineDetail",
                SalesItemLineDetail=dict(ItemRef={"value": provider}, Qty=quantity, UnitPrice=value["unitPrice"],
                    TaxCodeRef={"value": "TAX" if value["isTaxable"] else "NON"}))
        rows = [line(value) for value in (raw if isinstance(raw, list) else raw["lines"])]
        if isinstance(raw, dict) and raw.get("documentDiscount"):
            discount = raw["documentDiscount"]
            percent = discount["kind"] == "percentage"
            amount = (billing.gross_amount(rows) * Decimal(str(discount["value"])) / 100).quantize(Decimal(".01"), rounding=ROUND_HALF_UP) if percent else Decimal(str(discount["value"]))
            detail = {"PercentBased": percent}
            if percent:
                detail["DiscountPercent"] = discount["value"]
            rows.append(dict(Amount=float(amount), DetailType="DiscountLineDetail", DiscountLineDetail=detail))
        with backend.db() as connection:
            epoch = billing.billing_assignments.connection_revision(billing.grant_fingerprint(connection.execute("SELECT * FROM qbo_connections").fetchone()))
        return dict(companyID=self.company, realmID=self.realm, environment="sandbox", documentType="Invoice",
            connectionRevision=epoch, localDocumentID=self.invoice_id, localCustomerID=self.customer_id,
            serviceCallID=self.proposal["request"]["jobID"], operation="create",
            document=dict(CustomerRef={"value": "C1"}, TxnDate="2026-09-11", DueDate="2026-10-11", Line=rows,
                ApplyTaxAfterDiscount=True))

    def payment(self, **changes):
        return dict(id=str(uuid.uuid4()), companyID=self.company, realmID=self.realm, environment="sandbox",
            invoiceID=self.invoice_id, invoiceQuickBooksID="D1", customerQuickBooksID="C1", amountCents=100,
            rail="card", kind="charge", **changes)

    def read_invoice(self, context, identifier):
        return copy.deepcopy(self.remotes.get(identifier, dict(Id=identifier, CustomerRef={"value": "C1"},
            CurrencyRef={"value": "USD"}, Balance=100)))

    def catalog_payload(self):
        return dict(companyID=self.company, realmID=self.realm, environment="sandbox",
            localItemID=self.proposal["request"]["line"]["itemID"], operation="create",
            item=dict(Name="Synthetic new repair", Type="Service", UnitPrice=123.375, Taxable=False,
                IncomeAccountRef={"value": "income"}))

    def expect(self, code, action):
        with self.assertRaises(payments.AttemptError) as error:
            action()
        self.assertEqual(error.exception.code, code)
        return error.exception

    def count(self, table):
        with backend.db() as connection:
            return connection.execute("SELECT COUNT(*) FROM " + table).fetchone()[0]

    def test_prepared_claim_holds_catalog_invoice_and_payment(self):
        self.seed("catalog"); self.prepare()
        for action in (lambda: self.catalog.reserve(self.admin, self.catalog_payload()),
                       lambda: self.publisher.publish(self.admin, self.payload()),
                       lambda: self.journal.reserve(self.admin, self.payment())):
            self.expect("invoice_application_pending", action)
        for table in ("catalog_publications", "billing_publications", "payment_attempts"):
            self.assertEqual(self.count(table), 0)
        self.assertFalse(self.writes)

    def test_published_source_releases_catalog_but_not_payment(self):
        self.seed(); self.applied()
        self.assertEqual(self.catalog.reserve(self.admin, self.catalog_payload())["state"], "reserved")
        self.expect("invoice_application_pending", lambda: self.journal.reserve(self.admin, self.payment()))

    def test_exact_invoice_publication_binds_claim_then_releases_payment(self):
        self.seed(); original = self.applied()
        result = self.publisher.publish(self.admin, self.payload())
        self.assertEqual(result["publication"]["state"], "confirmed")
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.count("staff_invoice_application_publications"), 1)
        reserved = self.journal.reserve(self.admin, self.payment())
        self.assertEqual(self.journal.begin(self.admin, reserved["id"])["state"], "sending")
        self.assertEqual(self.owner.invoke(self.proposal, "confirm"), (200, original))

    def test_equal_total_changed_quantity_is_not_the_approved_sale(self):
        self.seed(); self.applied()
        payload = self.payload()
        detail = list(billing.sold_lines(payload["document"]["Line"]))[-1]["SalesItemLineDetail"]
        detail["Qty"] *= 2; detail["UnitPrice"] /= 2
        self.expect("invoice_application_changed", lambda: self.publisher.publish(self.admin, payload))
        self.assertEqual(self.count("billing_publications"), 0)
        self.assertEqual(self.count("billing_job_documents"), 0)
        self.assertFalse(self.writes)

    def test_omitted_job_and_wrong_item_or_tax_cannot_bind_claim(self):
        self.seed(); self.applied()
        for kind in ("job", "item", "tax", "order"):
            payload = self.payload()
            if kind == "job":
                payload.pop("serviceCallID")
            elif kind == "order":
                rows = payload["document"]["Line"]
                rows[0], rows[1] = rows[1], rows[0]
            else:
                detail = list(billing.sold_lines(payload["document"]["Line"]))[-1]["SalesItemLineDetail"]
                detail["ItemRef" if kind == "item" else "TaxCodeRef"] = {"value": next(iter(self.ids.values())) if kind == "item" else "TAX"}
            with self.subTest(kind=kind):
                self.expect("invoice_application_changed", lambda: self.publisher.reserve(self.admin, payload))
        self.assertEqual(self.count("staff_invoice_application_publications"), 0)

    def test_source_changes_after_reservation_block_final_send(self):
        self.seed(); self.applied()
        payload = self.payload()
        row = self.publisher.reserve(self.admin, payload)
        def change():
            changed = copy.deepcopy(self.proposal)
            changed["expectedInvoice"]["revision"] += 1
            fields.set_value(dict(kind="invoice", fields=changed["invoiceFields"]), "status", "paid")
            self.owner.publish(changed, item=False)
        self.before_write = change
        self.expect("invoice_application_changed", lambda: self.publisher.run(self.admin, row["id"], allow_send=True))
        self.assertFalse(self.writes)
        self.assertEqual(self.publisher.check(self.admin, row["id"])[0]["state"], "reserved")

    def test_existing_invoice_reservation_blocks_new_application(self):
        self.seed("catalog")
        row = self.publisher.reserve(self.admin, self.payload())
        result = self.owner.invoke(self.proposal)
        self.assertEqual(result[1]["code"], "invoice_provider_pending")
        self.assertEqual(self.count("staff_owner_invoice_applications"), 0)
        self.publisher.cancel(self.admin, row["id"])
        self.prepare()

    def test_existing_payment_blocks_new_application_until_unsent_cancel(self):
        self.seed()
        row = self.journal.reserve(self.admin, self.payment())
        self.assertEqual(self.owner.invoke(self.proposal)[1]["code"], "invoice_payment_pending")
        self.assertEqual(self.count("staff_owner_invoice_applications"), 0)
        self.journal.cancel(self.admin, row["id"])
        self.prepare()

    def test_existing_catalog_reservation_blocks_new_application(self):
        self.seed()
        row = self.catalog.reserve(self.admin, self.catalog_payload())
        self.assertEqual(self.owner.invoke(self.proposal)[1]["code"], "invoice_catalog_pending")
        self.catalog.cancel(self.admin, row["id"])
        self.prepare()

    def test_cancelled_publication_retains_link_and_exact_retry_can_confirm(self):
        self.seed(); self.applied()
        row = self.publisher.reserve(self.admin, self.payload())
        self.publisher.cancel(self.admin, row["id"])
        self.expect("invoice_application_pending", lambda: self.journal.reserve(self.admin, self.payment()))
        result = self.publisher.publish(self.admin, self.payload())
        self.assertNotEqual(result["publication"]["id"], row["id"])
        self.assertEqual(self.count("staff_invoice_application_publications"), 2)
        self.assertEqual(self.journal.reserve(self.admin, self.payment())["state"], "reserved")

    def test_unknown_publication_recovers_without_second_write(self):
        self.seed(); self.applied()
        def lost(_):
            raise TimeoutError("synthetic response loss")
        self.after_write = lost
        with self.assertRaises(TimeoutError):
            self.publisher.publish(self.admin, self.payload())
        with backend.db() as connection:
            row = dict(connection.execute("SELECT * FROM billing_publications").fetchone())
        self.assertIn(row["state"], ("sending", "unknown"))
        duplicate = self.payment(); duplicate["invoiceID"] = str(uuid.uuid4())
        self.expect("invoice_application_pending", lambda: self.journal.reserve(self.admin, duplicate))
        self.assertEqual(self.publisher.run(self.admin, row["id"])["publication"]["state"], "confirmed")
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.journal.reserve(self.admin, self.payment())["state"], "reserved")

    def test_duplicate_native_invoice_identity_cannot_bypass_pending_application(self):
        self.seed(); self.prepare()
        with backend.db() as connection:
            connection.execute("INSERT INTO billing_entity_mappings VALUES (?,?,'sandbox','Invoice',?,?,'D1')",
                (self.company, self.realm, self.invoice_id, self.customer_id))
        payload = self.payment(); payload["invoiceID"] = str(uuid.uuid4())
        self.expect("invoice_application_pending", lambda: self.journal.reserve(self.admin, payload))

    def test_final_payment_dispatch_checks_claim_even_after_reservation(self):
        self.seed()
        # Model a pre-migration reservation: seed a genuine approved claim,
        # restoring the old reservation only after its normal cancellation.
        row = self.journal.reserve(self.admin, self.payment())
        self.journal.cancel(self.admin, row["id"])
        self.prepare()
        with backend.db() as connection:
            connection.execute("UPDATE payment_attempts SET state='reserved' WHERE id=?", (row["id"],))
        self.expect("invoice_application_pending", lambda: self.journal.begin(self.admin, row["id"]))
        self.assertEqual(self.journal.get(self.admin, row["id"])["state"], "reserved")

    def test_final_catalog_dispatch_checks_claim_even_after_reservation(self):
        self.seed()
        row = self.catalog.reserve(self.admin, self.catalog_payload())
        self.catalog.cancel(self.admin, row["id"])
        self.prepare()
        with backend.db() as connection:
            connection.execute("UPDATE catalog_publications SET state='reserved' WHERE id=?", (row["id"],))
        self.expect("invoice_application_pending", lambda: self.catalog.claim(self.admin, row["id"]))

    def test_missing_link_or_changed_encrypted_link_prevents_dispatch(self):
        self.seed(); self.applied()
        row = self.publisher.reserve(self.admin, self.payload())
        with backend.db() as connection:
            ciphertext = connection.execute("SELECT ciphertext FROM staff_invoice_application_publications").fetchone()[0]
            proof = json.loads(backend.decrypt_catalog_payload(ciphertext)); proof["payloadHash"] = "0" * 64
            connection.execute("UPDATE staff_invoice_application_publications SET ciphertext=?", (backend.encrypt_catalog_payload(json.dumps(proof)),))
        self.expect("storage_unavailable", lambda: self.publisher.claim(self.admin, row["id"]))
        with backend.db() as connection:
            connection.execute("DELETE FROM staff_invoice_application_publications")
        self.expect("invoice_application_changed", lambda: self.publisher.claim(self.admin, row["id"]))
        self.assertFalse(self.writes)

    def test_encryption_failure_rolls_back_publication_and_job_binding(self):
        self.seed(); self.applied()
        encrypt = backend.encrypt_catalog_payload
        def reject_link(raw):
            if 'office-invoice-publication-v1' in raw:
                raise RuntimeError("synthetic encryption unavailable")
            return encrypt(raw)
        self.publisher.encrypt = reject_link
        self.expect("storage_unavailable", lambda: self.publisher.reserve(self.admin, self.payload()))
        for table in ("billing_publications", "staff_invoice_application_publications", "billing_job_documents"):
            self.assertEqual(self.count(table), 0)

    def test_unverifiable_claim_metadata_is_not_skipped_by_catalog_state_filter(self):
        self.seed(); self.prepare()
        with backend.db() as connection:
            connection.execute("UPDATE staff_owner_invoice_applications SET state='published'")
        error = self.expect("storage_unavailable", lambda: self.catalog.reserve(self.admin, self.catalog_payload()))
        self.assertEqual(error.status, 503)

    def test_missing_decrypt_fails_closed_only_when_relevant_claim_exists(self):
        self.seed()
        legacy = payments.PaymentAttemptJournal(backend.db, self.read_invoice, mock.Mock(), mock.Mock(), backend.record_audit_event)
        row = legacy.reserve(self.admin, self.payment())
        legacy.cancel(self.admin, row["id"])
        self.prepare()
        self.expect("storage_unavailable", lambda: legacy.reserve(self.admin, self.payment()))

    def test_native_group_uppercase_company_scope_and_itemized_packages_publish(self):
        self.seed("catalog_group"); self.applied()
        result = self.publisher.publish(self.admin, self.payload())
        self.assertEqual(result["publication"]["state"], "confirmed")
        self.assertEqual(self.writes[0][1]["Line"][0]["DetailType"], "GroupLineDetail")

    def test_itemized_package_publishes_all_sold_components(self):
        self.seed("catalog_assembly"); self.applied()
        self.publisher.publish(self.admin, self.payload())
        sold = list(billing.sold_lines(self.writes[0][1]["Line"]))
        self.assertEqual(len(sold), 4)  # Two original group members plus two added parts.
        self.assertEqual([row["SalesItemLineDetail"]["Qty"] for row in sold[-2:]], [4, 6])

    def test_percentage_discount_preserves_half_cent_rounding(self):
        self.seed()
        raw = json.loads(applications.atom(self.proposal["invoiceFields"], "catalogSnapshotJSON"))
        rows = raw if isinstance(raw, list) else raw["lines"]
        self.assertEqual(billing.gross_amount(self.payload()["document"]["Line"]), Decimal("471.75"))
        snapshot = dict(version=1, lines=rows, documentDiscount=dict(kind="percentage", value=10,
            grossSubtotalAtAuthorization=471.75, reason="Synthetic approved discount", authorizedByEmail="admin@gunnaire.com",
            authorizedAt=self.proposal["newItemFields"]["pricebookReviewedAt"]["date"]["_0"]))
        invoice = dict(kind="invoice", fields=self.proposal["invoiceFields"])
        fields.set_value(invoice, "catalogSnapshotJSON", json.dumps(snapshot))
        fields.set_value(invoice, "amount", 424.57)
        self.applied()
        self.publisher.publish(self.admin, self.payload())
        self.assertEqual(self.writes[0][1]["Line"][-1]["Amount"], 47.18)

    def test_new_item_cannot_reuse_an_old_shared_provider_mapping(self):
        self.seed()
        with backend.db() as connection:
            connection.execute("INSERT INTO catalog_entity_mappings VALUES (?,?,'sandbox',?,'OLD-ITEM')",
                (self.company, self.realm, self.proposal["request"]["line"]["itemID"]))
        self.assertEqual(self.owner.invoke(self.proposal)[1]["code"], "invoice_catalog_pending")
        self.assertEqual(self.count("staff_owner_invoice_applications"), 0)

    def test_approval_and_payment_reservation_race_has_only_one_winner(self):
        self.seed()
        payload = self.payment()
        def reserve():
            try:
                return 200, self.journal.reserve(self.admin, payload)
            except payments.AttemptError as error:
                return error.status, dict(code=error.code)
        with ThreadPoolExecutor(max_workers=2) as pool:
            claim = pool.submit(self.owner.invoke, self.proposal)
            payment = pool.submit(reserve)
            results = [claim.result(timeout=10), payment.result(timeout=10)]
        self.assertEqual(sorted(result[0] for result in results), [200, 409])
        self.assertEqual(self.count("staff_owner_invoice_applications") + self.count("payment_attempts"), 1)
        self.assertFalse(self.writes)

    def test_http_payment_handler_uses_the_same_claim_guard_and_decryptor(self):
        self.seed(); self.applied()
        payload = self.payment()
        with mock.patch.object(backend, "read_payment_provider_record", side_effect=lambda context, kind, identifier, **kwargs: self.read_invoice(context, identifier)):
            request = lambda: self.owner.request(token=self.owner.tokens["Admin"], method="POST", path="/api/payment-attempts", payload=payload)
            self.assertEqual(request()[1]["code"], "invoice_application_pending")
            self.publisher.publish(self.admin, self.payload())
            status, result = request()
        self.assertEqual(status, 200, result)
        self.assertEqual(result["attempt"]["state"], "reserved")

    def test_multiple_approved_requests_publish_as_one_complete_invoice(self):
        self.seed(); self.applied()
        first_command = self.proposal["commandID"]
        invoice = fields.row(self.owner.records, "invoice")
        invoice.update(fields=copy.deepcopy(self.proposal["invoiceFields"]), revision=invoice["revision"] + 1)
        self.owner.records.append(dict(invoice, kind="item", id=self.proposal["request"]["line"]["itemID"],
            revision=1, fields=copy.deepcopy(self.proposal["newItemFields"])))
        with backend.db() as connection:
            self.owner.sequence = connection.execute("SELECT sequence FROM staff_workspace_source_heads").fetchone()[0]
        self.owner.refresh(invoice)
        with mock.patch.object(self.owner, "seed_content", return_value=None):
            self.proposal = self.owner.seed_proposal()
        self.ids[self.proposal["request"]["line"]["itemID"]] = "I-second"
        self.applied()
        self.publisher.publish(self.admin, self.payload())
        with backend.db() as connection:
            links = connection.execute("SELECT command_id,publication_id FROM staff_invoice_application_publications").fetchall()
        self.assertEqual({row[0] for row in links}, {first_command, self.proposal["commandID"]})
        self.assertEqual(len({row[1] for row in links}), 1)
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.journal.reserve(self.admin, self.payment())["state"], "reserved")

    def test_existing_qbo_invoice_requires_original_update_not_new_create(self):
        self.seed("catalog")
        fields.set_value(self.proposal["expectedInvoice"], "quickBooksID", "D-existing")
        fields.set_value(dict(kind="invoice", fields=self.proposal["invoiceFields"]), "quickBooksID", "D-existing")
        fields.set_value(dict(kind="invoice", fields=self.proposal["invoiceFields"]), "quickBooksSyncStatus", "balance_needs_refresh")
        self.owner.refresh(self.proposal["expectedInvoice"])
        self.applied()
        self.expect("invoice_application_changed", lambda: self.publisher.reserve(self.admin, self.payload()))
        payload = self.payload()
        payload.update(operation="update")
        payload["document"].update(Id="D-existing", SyncToken="0", sparse=True)
        with backend.db() as connection:
            connection.execute("INSERT INTO billing_entity_mappings VALUES (?,?,'sandbox','Invoice',?,?,'D-existing')",
                (self.company, self.realm, self.invoice_id, self.customer_id))
        self.remotes["D-existing"] = dict(copy.deepcopy(payload["document"]), TotalAmt=100, Balance=100,
            CurrencyRef={"value": "USD"}, TxnTaxDetail={"TotalTax": 0})
        result = self.publisher.publish(self.admin, payload)
        self.assertEqual(result["publication"]["providerID"], "D-existing")
        payment = self.payment(); payment["invoiceQuickBooksID"] = "D-existing"
        self.assertEqual(self.journal.reserve(self.admin, payment)["state"], "reserved")

    def test_wrong_provider_financial_confirmation_never_releases_collection(self):
        self.seed(); self.applied()
        def wrong(remote):
            remote["Line"][-1]["Amount"] += 1
            return remote
        self.after_write = wrong
        self.expect("provider_unconfirmed", lambda: self.publisher.publish(self.admin, self.payload()))
        self.expect("billing_needs_review", lambda: self.journal.reserve(self.admin, self.payment()))
        self.assertEqual(len(self.writes), 1)

    def test_confirmed_publication_cannot_release_a_different_provider_invoice(self):
        self.seed(); self.applied()
        self.publisher.publish(self.admin, self.payload())
        payment = self.payment(); payment["invoiceQuickBooksID"] = "UNRELATED"
        self.expect("invoice_application_pending", lambda: self.journal.reserve(self.admin, payment))

    def test_confirmed_publication_cannot_release_another_qbo_environment(self):
        self.seed(); self.applied()
        self.publisher.publish(self.admin, self.payload())
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET environment='production'")
        payment = self.payment(); payment["environment"] = "production"
        self.expect("invoice_application_pending", lambda: self.journal.reserve(self.admin, payment))

    def test_claim_recovery_does_not_require_new_provider_mutation(self):
        self.seed(); receipt = self.applied()
        row = self.publisher.reserve(self.admin, self.payload())
        self.assertEqual(self.owner.invoke(self.proposal), (200, receipt))
        self.assertEqual(self.owner.invoke(self.proposal, "confirm"), (200, receipt))
        self.assertEqual(self.publisher.reserve(self.admin, self.payload())["id"], row["id"])
        self.assertFalse(self.writes)

    def test_invalid_provider_lines_remain_recovery_errors_not_local_input_errors(self):
        self.seed()
        original = self.payload()["document"]["Line"]
        for kind in ("amount", "quantity", "reference", "discount"):
            changed = copy.deepcopy(original)
            leaf = list(billing.sold_lines(changed))[0]
            if kind == "amount":
                leaf["Amount"] = float("inf")
            elif kind == "quantity":
                leaf["SalesItemLineDetail"]["Qty"] = 0
            elif kind == "reference":
                leaf["SalesItemLineDetail"]["ItemRef"] = {"value": "invalid provider reference"}
            else:
                changed[-1]["Amount"] += 1
            with self.subTest(kind=kind):
                error = self.expect("provider_unconfirmed", lambda: billing.provider_line_values(changed))
                self.assertEqual(error.status, 409)

    def test_intervening_qbo_identity_or_progress_billing_blocks_old_dispatch(self):
        self.seed(); self.applied()
        row = self.publisher.reserve(self.admin, self.payload())
        revision = self.proposal["expectedInvoice"]["revision"] + 1
        for key, value in (("quickBooksID", "D-intervening"), ("projectMilestoneID", str(uuid.uuid4())),
                           ("milestoneDraftReceiptJSON", "{}")):
            changed = copy.deepcopy(self.proposal)
            changed["expectedInvoice"]["revision"] = revision
            fields.set_value(dict(kind="invoice", fields=changed["invoiceFields"]), key, value)
            self.owner.publish(changed, item=False)
            with self.subTest(field=key):
                self.expect("invoice_application_changed", lambda: self.publisher.claim(self.admin, row["id"]))
            changed["expectedInvoice"]["revision"] += 1
            changed["invoiceFields"] = copy.deepcopy(self.proposal["invoiceFields"])
            self.owner.publish(changed, item=False)
            revision += 2
        self.assertEqual(self.publisher.check(self.admin, row["id"])[0]["state"], "reserved")
        self.assertFalse(self.writes)


if __name__ == "__main__":
    unittest.main()
