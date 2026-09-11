"""Explicit office invoice proposals, exclusive recovery claims and source proof.

Preparing a proposal does not change an invoice, item, CloudKit record or QBO.
Confirmation requires the exact approved invoice and new item to have reached
the owner source. Provider publication remains a separate reviewed workflow.
"""
from __future__ import annotations

import copy
from collections import defaultdict
from decimal import Decimal, InvalidOperation

try:
    from Backend import staff_invoice_lines as lines, staff_billing_projection as billing
except ModuleNotFoundError:
    import staff_invoice_lines as lines
    import staff_billing_projection as billing

contract, sharing, source = lines.contract, lines.sharing, lines.source
SCHEMA = "staff-owner-invoice-application-v1"
PREPARE = lines.SCOPE + " schema commandID operationID ownerStoreID request expectedInvoice invoiceFields newItemFields dependencies reviewed reason"
CONFIRM = lines.SCOPE + " schema commandID operationID ownerStoreID"
MAX_BYTES = 7 * 1024 * 1024
MAX_HISTORY_BYTES = 64 * 1024 * 1024
INVOICE_CHANGES = set("catalogSnapshotJSON lineItemSummary amount salesTaxAmount taxCalculationStatusRawValue taxCalculatedAt quickBooksSyncStatus quickBooksSyncDetail customerSignatureName customerSignatureImageBase64 customerSignedAt".split())


def initialize_schema(connection):
    lines.initialize_schema(connection)
    connection.execute("""CREATE TABLE IF NOT EXISTS staff_owner_invoice_applications (
        command_id TEXT PRIMARY KEY, operation_id TEXT NOT NULL UNIQUE,
        company_id TEXT NOT NULL, environment TEXT NOT NULL, replica_id TEXT NOT NULL,
        invoice_id TEXT NOT NULL, owner_email TEXT NOT NULL, owner_store_id TEXT NOT NULL,
        state TEXT NOT NULL, ciphertext TEXT NOT NULL
    )""")
    connection.execute("""CREATE UNIQUE INDEX IF NOT EXISTS staff_owner_invoice_one_pending
        ON staff_owner_invoice_applications(company_id,environment,replica_id,invoice_id)
        WHERE state='prepared'""")


def fail(code, message, status=409):
    return sharing.fail(code, message, status)


def record(value, scope):
    contract.exact(value, lines.RECORD)
    sharing.identifier(value["id"])
    contract.integer(value["revision"], 1)
    if (value["deleted"] is not False or value["schema"] != contract.SCHEMA_VERSION
            or value["schemaDigest"] != contract.SCHEMA_DIGEST
            or any(value[key] != expected for key, expected in zip(lines.SCOPE.split(), scope[:3]))):
        raise contract.invalid()
    contract.validate(value["kind"], value["fields"])


def atom(fields, key):
    spec = contract.SPECS["invoice"].get(key)
    if spec is None:
        raise contract.invalid()
    return lines.atom(fields, key, spec["type"], spec["nullable"])


class ProposalGraph:
    """Only records the owner explicitly reviewed can inform the proposal."""
    def __init__(self, records):
        self.records = {(r["kind"], r["id"]): r for r in records}
        self.live = defaultdict(dict)
        for (kind, identifier), value in self.records.items():
            self.live[kind][identifier] = value

    def value(self, kind, identifier, field):
        record = self.records.get((kind, identifier.lower()))
        if record is None:
            raise fail("invoice_dependencies_changed", "Review the complete original customer, system and catalog records.")
        spec = contract.SPECS[kind][field]
        value = lines.atom(record["fields"], field, spec["type"], spec["nullable"])
        return value.lower() if value is not None and spec["type"] == "identifier" else value


class StaffOwnerInvoiceApplications(lines.StaffInvoiceLines):
    def original_request(self, connection, scope, command_id):
        row = connection.execute("""SELECT * FROM staff_invoice_line_requests
            WHERE command_id=? AND company_id=? AND environment=? AND replica_id=?""", (command_id, *scope[:3])).fetchone()
        if row is None:
            raise fail("request_not_found", "This invoice request is not in the current business.", 404)
        saved = self.saved(row)
        if any(saved["request"][key] != expected for key, expected in zip(lines.SCOPE.split(), scope[:3])):
            raise self.source.unavailable()
        return saved

    def current(self, connection, scope, kind, identifier):
        row = connection.execute("SELECT * FROM staff_workspace_source_records WHERE " + source.WHERE + " AND kind=? AND record_id=?",
                                 (*scope, kind, identifier)).fetchone()
        return self.source.decode_record(row) if row is not None else None

    def validate_proposal(self, payload, original, scope, actor_email, prepared_at=None):
        contract.exact(payload, PREPARE)
        if payload["schema"] != SCHEMA or payload["reviewed"] is not True:
            raise contract.invalid()
        for key in ("commandID", "operationID", "ownerStoreID"):
            sharing.identifier(payload[key])
        if any(payload[key] != expected for key, expected in zip(lines.SCOPE.split(), scope[:3])):
            raise contract.invalid()
        lines.text(payload["reason"], 2000)
        lines.validate(payload["request"])
        if payload["request"] != original["request"] or payload["commandID"] != original["request"]["commandID"]:
            raise fail("invoice_request_changed", "Keep the original technician request unchanged.")
        invoice, request = payload["expectedInvoice"], original["request"]
        record(invoice, scope)
        if invoice["kind"] != "invoice" or invoice["id"] != request["invoiceID"]:
            raise contract.invalid()
        contract.integer(invoice["revision"] + 1, 1)
        before, after = invoice["fields"], payload["invoiceFields"]
        contract.validate("invoice", after)
        if (atom(before, "status") not in ("unpaid", "overdue") or atom(before, "finalizedAt") is not None
                or atom(before, "projectMilestoneID") is not None or atom(before, "milestoneDraftReceiptJSON") is not None):
            raise fail("invoice_locked", "Use the office correction or progress-billing workflow for this invoice.")
        if (lines.identifier_field(before, "customer") != request["customerID"]
                or lines.identifier_field(before, "serviceCallID") != request["jobID"]
                or any(before[key] != after[key] for key in before if key not in INVOICE_CHANGES)):
            raise fail("invoice_scope_changed", "Keep this invoice's customer, job, payment and accounting identities unchanged.")
        if before["catalogSnapshotJSON"] == after["catalogSnapshotJSON"]:
            raise fail("invoice_proposal_empty", "Review the requested invoice line before preparing its application.")
        if (atom(after, "salesTaxAmount") != 0 or atom(after, "taxCalculatedAt") is not None
                or any(atom(after, key) is not None for key in ("customerSignedAt", "customerSignatureName", "customerSignatureImageBase64"))):
            raise fail("invoice_approval_stale", "Changed invoice lines need fresh tax and customer approval evidence.")
        expected_sync = "balance_needs_refresh" if atom(before, "quickBooksID") else "pending"
        if atom(after, "quickBooksSyncStatus") != expected_sync:
            raise fail("invoice_provider_review_required", "Keep this changed invoice pending QuickBooks review, not synced.")
        dependencies = payload["dependencies"]
        if type(dependencies) is not list or len(dependencies) > 1000:
            raise contract.invalid()
        seen = set()
        for dependency in dependencies:
            record(dependency, scope)
            key = (dependency["kind"], dependency["id"])
            if dependency["kind"] not in ("customer", "job", "location", "equipment", "item") or key in seen:
                raise contract.invalid()
            seen.add(key)
        required = {("customer", request["customerID"])}
        if request["jobID"]:
            required.add(("job", request["jobID"]))
        location_id = lines.identifier_field(before, "serviceLocationID")
        if location_id:
            required.add(("location", location_id))
        if request["line"]["equipmentID"]:
            required.add(("equipment", request["line"]["equipmentID"]))
        if request["line"]["kind"] == "catalog":
            required.add(("item", request["line"]["itemID"]))
        if not required <= seen:
            raise fail("invoice_dependencies_changed", "Review the original customer, job, system and catalog item.")
        new_item = payload["newItemFields"]
        proposed = dict(invoice, fields=after)
        records = dependencies + [proposed]
        if request["line"]["kind"] == "new":
            contract.validate("item", new_item)
            if (("item", request["line"]["itemID"]) in seen or not lines.item_matches(request["line"], new_item)
                    or lines.atom(new_item, "quickBooksID", "text", True) is not None
                    or lines.atom(new_item, "quickBooksSyncStatus", "text") != "pending"
                    or lines.atom(new_item, "pricebookReviewStatusRawValue", "text", True) != "approved"
                    or lines.atom(new_item, "pricebookReviewedByEmail", "text", True) != actor_email
                    or lines.atom(new_item, "pricebookCreatedByEmail", "text", True) != original["receipt"]["actorEmail"]
                    or lines.atom(new_item, "tracksInventory", "flag") is not False):
                raise fail("invoice_new_item_changed", "Review the exact new service or non-inventory item under the original author and office approver.")
            for key, spec in contract.SPECS["item"].items():
                if key.startswith("quickBooks") and key not in ("quickBooksSyncStatus", "quickBooksSyncDetail"):
                    if lines.atom(new_item, key, spec["type"], spec["nullable"]) is not None:
                        raise fail("invoice_new_item_changed", "A newly reviewed item cannot inherit another item's provider evidence.")
            purchase_cost = lines.atom(new_item, "purchaseCost", "number", True)
            if purchase_cost is not None:
                billing.number(purchase_cost)
            reviewed_at = lines.atom(new_item, "pricebookReviewedAt", "date", True)
            recorded_at = lines.owner_edits.instant(original["receipt"]["createdAt"]).timestamp() - 978307200
            prepared = lines.owner_edits.instant(prepared_at) if prepared_at else self.shares.now()
            if reviewed_at is None or not recorded_at - 300 <= reviewed_at <= prepared.timestamp() - 978307200 + 300:
                raise fail("invoice_new_item_changed", "Record the current office review time for the new pricebook item.")
            records.append(dict(invoice, kind="item", id=request["line"]["itemID"], revision=1, fields=new_item))
        elif new_item is not None:
            raise contract.invalid()
        graph = ProposalGraph(records)
        for kind, identifier in (("job", request["jobID"]), ("location", location_id)):
            if identifier and graph.value(kind, identifier, "customer") != request["customerID"]:
                raise fail("invoice_scope_changed", "Keep the job and service location within the original customer.")
        view = billing.Catalog(graph, proposed).read(atom(after, "catalogSnapshotJSON"))
        leaves = [leaf for root in view["lines"] for leaf in
                  ([entry["line"] for entry in root["bundle"]["members"]] if "bundle" in root else [root])]
        expected_tax = "pending_quickbooks" if any(leaf["isTaxable"] for leaf in leaves) else "not_applicable"
        if atom(after, "taxCalculationStatusRawValue") != expected_tax:
            raise fail("invoice_tax_review_required", "Recalculate tax from the approved invoice lines before customer commitment.")
        root_id = request["line"]["itemID"].upper()
        components = [r for r in view["lines"] if r["catalogItemID"] != root_id and r.get("assembly", {}).get("assemblyItemID") == root_id
                      and r.get("assembly", {}).get("presentation") == "itemized"]
        if components:
            recipe = components[0]["assembly"]
            if (request["line"]["kind"] != "catalog" or request["line"]["itemType"] != "Service"
                    or any(row["assembly"] != recipe for row in components)
                    or {row["catalogItemID"] for row in components} != {c["itemID"] for c in recipe["components"]}):
                raise fail("invoice_package_changed", "Keep every included item from one complete reviewed package revision.")
            # An older flat-rate sale of this catalog item remains unchanged;
            # the new itemized request adds only its component quantities.
            requested_rows = components
        else:
            requested_rows = [r for r in view["lines"] if r["catalogItemID"] == root_id]
        if not requested_rows:
            raise fail("invoice_request_missing", "The reviewed invoice must include the original requested item or its resolved package.")
        old_raw = atom(before, "catalogSnapshotJSON")
        if old_raw is None:
            if atom(before, "amount") != 0 or atom(before, "salesTaxAmount") != 0:
                raise fail("invoice_manual_lines_required", "Itemize the existing manual amount before adding requested work; do not replace its balance.")
            old_rows = []
        else:
            old_graph = ProposalGraph([r for r in records if r["kind"] != "invoice"] + [invoice])
            old_rows = billing.Catalog(old_graph, invoice).read(old_raw)["lines"]
        previous = {r["catalogItemID"]: r for r in old_rows}
        proposed_rows = {r["catalogItemID"]: r for r in view["lines"]}
        affected = {r["catalogItemID"] for r in requested_rows}
        if (not set(previous) <= set(proposed_rows) or not (set(proposed_rows) - set(previous)) <= affected
                or any(proposed_rows[key] != value for key, value in previous.items() if key not in affected)):
            raise fail("invoice_unrelated_lines_changed", "Retain every unrelated original invoice line. Review other changes separately.")
        for row in requested_rows:
            added = Decimal(str(request["line"]["quantity"]))
            if row["catalogItemID"] != root_id:
                components = [c for c in row["assembly"]["components"] if c["itemID"] == row["catalogItemID"]]
                if len(components) != 1:
                    raise fail("invoice_package_changed", "Review the complete quantity of each resolved package component.")
                added *= Decimal(str(components[0]["quantity"]))
            prior = Decimal(str(previous.get(row["catalogItemID"], {}).get("quantity", 0)))
            if Decimal(str(row["quantity"])) != prior + added:
                raise fail("invoice_quantity_changed", "Add exactly the requested quantity while retaining the original sold quantity.")
        if request["line"]["equipmentID"] and any(r.get("servicedEquipment", {}).get("equipmentID", "").lower() != request["line"]["equipmentID"] for r in requested_rows):
            raise fail("invoice_equipment_changed", "Keep the technician's serviced system linked to the requested invoice work.")
        if len(contract.wire(payload).encode()) > MAX_BYTES:
            raise contract.invalid()
        return records

    def application(self, connection, scope, command_id):
        row = connection.execute("SELECT * FROM staff_owner_invoice_applications WHERE command_id=?", (command_id,)).fetchone()
        if row is None:
            return None
        saved = self.source.decode(row["ciphertext"])
        try:
            contract.exact(saved, "proposal receipt")
            receipt, proposal = saved["receipt"], saved["proposal"]
            contract.exact(receipt, "schema companyID environment replicaID commandID operationID ownerStoreID ownerEmail invoiceID preparedAt state publishedAt qboPublished proposalSHA256")
            original = self.original_request(connection, scope, command_id)
            self.validate_proposal(proposal, original, scope, row["owner_email"], prepared_at=receipt["preparedAt"])
            expected = self.application_receipt(proposal, row["owner_email"], receipt["preparedAt"], row["state"], receipt["publishedAt"])
            if contract.canonical(receipt) != contract.canonical(expected) or any(row[column] != receipt[key] for column, key in (
                    ("company_id", "companyID"), ("environment", "environment"), ("replica_id", "replicaID"),
                    ("command_id", "commandID"), ("operation_id", "operationID"), ("owner_store_id", "ownerStoreID"), ("invoice_id", "invoiceID"))):
                raise ValueError()
            prepared = lines.owner_edits.instant(receipt["preparedAt"])
            if prepared < lines.owner_edits.instant(original["receipt"]["createdAt"]):
                raise ValueError()
            if receipt["state"] not in ("prepared", "published") or (receipt["state"] == "prepared") != (receipt["publishedAt"] is None):
                raise ValueError()
            if receipt["publishedAt"] is not None and lines.owner_edits.instant(receipt["publishedAt"]) < prepared:
                raise ValueError()
        except (sharing.AttemptError, ValueError, TypeError, KeyError, AttributeError, InvalidOperation, RecursionError):
            raise self.source.unavailable() from None
        return saved

    @staticmethod
    def application_receipt(proposal, actor, prepared_at, state="prepared", published_at=None):
        return dict(schema=SCHEMA, **{key: proposal[key] for key in lines.SCOPE.split()},
            commandID=proposal["commandID"], operationID=proposal["operationID"], ownerStoreID=proposal["ownerStoreID"],
            ownerEmail=actor, invoiceID=proposal["request"]["invoiceID"], preparedAt=prepared_at, state=state,
            publishedAt=published_at, qboPublished=False, proposalSHA256=lines.record_hash(proposal))

    def read_application(self, session_id, command_id, query):
        contract.exact(query, lines.SCOPE)
        sharing.identifier(command_id)
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            initialize_schema(connection)
            actor, scope = self.source.scope(connection, session_id, query)
            self.original_request(connection, scope, command_id)
            result = self.application(connection, scope, command_id)
            self.shares.audit(actor["email"], "review-invoice-application", "staff-invoice-line", command_id, connection=connection)
            return dict(schema=SCHEMA, application=result)

    def change(self, session_id, command_id, action, payload):
        if action not in ("prepare", "confirm"):
            raise contract.invalid()
        contract.exact(payload, PREPARE if action == "prepare" else CONFIRM)
        if payload["schema"] != SCHEMA or payload["commandID"] != command_id:
            raise contract.invalid()
        for key in ("commandID", "operationID", "ownerStoreID"):
            sharing.identifier(payload[key])
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            initialize_schema(connection)
            actor, scope = self.source.scope(connection, session_id, payload)
            original = self.original_request(connection, scope, command_id)
            existing = self.application(connection, scope, command_id)
            if existing:
                receipt = existing["receipt"]
                if receipt["ownerEmail"] != actor["email"] or any(receipt[key] != payload[key] for key in ("operationID", "ownerStoreID")):
                    raise fail("invoice_claimed", "Recover this approved proposal using its original office account and device.")
                if action == "prepare" and contract.canonical(existing["proposal"]) != contract.canonical(payload):
                    raise fail("invoice_proposal_changed", "Keep the original approved invoice proposal unchanged.")
                if receipt["state"] == "published":
                    return receipt
                if action == "prepare":
                    current = self.current(connection, scope, "invoice", original["request"]["invoiceID"])
                    proposed = existing["proposal"]
                    already_saved = (current is not None and not current["deleted"] and current["revision"] > proposed["expectedInvoice"]["revision"]
                                     and current["fields"] == proposed["invoiceFields"])
                    if not already_saved and (current != proposed["expectedInvoice"] or any(
                            self.current(connection, scope, dep["kind"], dep["id"]) != dep for dep in proposed["dependencies"])):
                        raise fail("invoice_changed", "Company records changed after this proposal was prepared. Retain the original claim for office review.")
                    return receipt
            elif action == "confirm":
                raise fail("invoice_not_prepared", "Prepare the original reviewed proposal before confirming its company records.")
            if action == "prepare":
                self.validate_proposal(payload, original, scope, actor["email"])
                invoice = payload["expectedInvoice"]
                if self.current(connection, scope, "invoice", invoice["id"]) != invoice:
                    raise fail("invoice_changed", "The office invoice changed. Review the current saved invoice before approving.")
                for dependency in payload["dependencies"]:
                    if self.current(connection, scope, dependency["kind"], dependency["id"]) != dependency:
                        raise fail("invoice_dependencies_changed", "The reviewed catalog, customer or system changed. Review its current values.")
                item_id = payload["request"]["line"]["itemID"]
                if payload["newItemFields"] is not None and self.current(connection, scope, "item", item_id) is not None:
                    raise fail("invoice_item_exists", "Recover the original item identity instead of creating another item.")
                if connection.execute("SELECT 1 FROM staff_owner_invoice_applications WHERE operation_id=? OR (company_id=? AND environment=? AND replica_id=? AND invoice_id=? AND state='prepared')",
                        (payload["operationID"], *scope[:3], invoice["id"])).fetchone():
                    raise fail("invoice_claimed", "Finish the original pending invoice proposal before preparing another.")
                receipt = self.application_receipt(payload, actor["email"], self.shares.now().isoformat())
                if lines.owner_edits.instant(receipt["preparedAt"]) < lines.owner_edits.instant(original["receipt"]["createdAt"]):
                    raise self.source.unavailable()
                contract.integer(self.source.sequence(connection, scope) + 1, 1)
                ciphertext = self.source.encode(dict(proposal=copy.deepcopy(payload), receipt=receipt))
                retained = connection.execute("SELECT COALESCE(SUM(LENGTH(ciphertext)),0) FROM staff_owner_invoice_applications WHERE company_id=? AND environment=? AND replica_id=?", scope[:3]).fetchone()[0]
                if retained + len(ciphertext.encode()) > MAX_HISTORY_BYTES:
                    raise fail("invoice_application_capacity", "Office invoice recovery history needs coordinated archival review. Existing proposals are retained.")
                connection.execute("INSERT INTO staff_owner_invoice_applications VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (command_id, payload["operationID"], *scope[:3], invoice["id"], actor["email"], payload["ownerStoreID"], "prepared",
                     ciphertext))
            else:
                proposal = existing["proposal"]
                invoice = self.current(connection, scope, "invoice", original["request"]["invoiceID"])
                if (invoice is None or invoice["deleted"] or invoice["revision"] <= proposal["expectedInvoice"]["revision"]
                        or invoice["fields"] != proposal["invoiceFields"]):
                    raise fail("invoice_not_published", "The exact approved invoice has not reached the company source. Keep its original proposal for recovery.")
                if proposal["newItemFields"] is not None:
                    item = self.current(connection, scope, "item", original["request"]["line"]["itemID"])
                    if item is None or item["deleted"] or item["fields"] != proposal["newItemFields"]:
                        raise fail("invoice_not_published", "The exact approved new item has not reached the company source.")
                receipt = dict(existing["receipt"], state="published", publishedAt=self.shares.now().isoformat())
                if lines.owner_edits.instant(receipt["publishedAt"]) < lines.owner_edits.instant(receipt["preparedAt"]):
                    raise self.source.unavailable()
                connection.execute("UPDATE staff_owner_invoice_applications SET state='published',ciphertext=? WHERE command_id=?",
                    (self.source.encode(dict(proposal=proposal, receipt=receipt)), command_id))
            self.shares.audit(actor["email"], action + "-invoice-application", "staff-invoice-line", command_id, connection=connection)
            return receipt
