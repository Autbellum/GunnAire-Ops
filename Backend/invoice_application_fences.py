"""Shared transaction fences for office invoice applications and QBO recovery.

No provider call or database transaction is started here. Callers authorize the
current actor, acquire BEGIN IMMEDIATE, then use these checks before reserving
or dispatching a mutation. Recovery of an already-sent request remains possible.
"""
from __future__ import annotations

from decimal import Decimal
from types import SimpleNamespace


def modules():
    # Lazy imports avoid payment/catalog/billing/application import cycles.
    try:
        from Backend import staff_owner_invoice_applications as applications, billing_publications as billing
    except ModuleNotFoundError:
        import staff_owner_invoice_applications as applications
        import billing_publications as billing
    return applications, billing


def fail(code="invoice_application_pending", message="Finish the original office invoice approval and QuickBooks sync before this action.", status=409):
    try:
        from Backend.payment_attempts import AttemptError
    except ModuleNotFoundError:
        from payment_attempts import AttemptError
    return AttemptError(code, message, status)


def exists(connection, table):
    return connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone() is not None


def initialize_schema(connection):
    connection.execute("""CREATE TABLE IF NOT EXISTS staff_invoice_application_publications (
        command_id TEXT NOT NULL, publication_id TEXT NOT NULL, ciphertext TEXT NOT NULL,
        PRIMARY KEY(command_id,publication_id)
    )""")
    connection.execute("CREATE INDEX IF NOT EXISTS staff_invoice_application_publication ON staff_invoice_application_publications(publication_id)")


def saved_applications(connection, company, decrypt, now, *, invoice_ids=None, prepared_only=False):
    if not exists(connection, "staff_owner_invoice_applications"):
        return
    if not exists(connection, "staff_invoice_application_publications"):
        raise fail("storage_unavailable", "Office invoice recovery storage needs review.", 503)
    sql, arguments = "SELECT * FROM staff_owner_invoice_applications WHERE company_id=?", [company]
    if invoice_ids is not None:
        if not invoice_ids:
            return
        sql += " AND invoice_id IN (" + ",".join("?" for _ in invoice_ids) + ")"
        arguments.extend(sorted(invoice_ids))
    applications, _ = modules()
    service = applications.StaffOwnerInvoiceApplications(SimpleNamespace(decrypt=decrypt, now=now))
    for row in connection.execute(sql + " ORDER BY command_id", arguments):
        if decrypt is None:
            raise fail("storage_unavailable", "Office invoice recovery could not be verified.", 503)
        scope = (company, row["environment"], row["replica_id"], applications.contract.SCHEMA_VERSION)
        value = service.application(connection, scope, row["command_id"])
        if value is None:
            raise fail("storage_unavailable", "The original invoice claim is unavailable.", 503)
        if not prepared_only or value["receipt"]["state"] == "prepared":
            yield value


def invoice_aliases(connection, intent, provider_id):
    intent = dict(intent)
    local_id = intent.get("local_document_id", intent.get("invoice_id"))
    identifiers, mapped = {local_id}, False
    if provider_id and exists(connection, "billing_entity_mappings"):
        for row in connection.execute("""SELECT local_document_id FROM billing_entity_mappings
                WHERE company_id=? AND realm_id=? AND environment=? AND document_type='Invoice' AND provider_id=?""",
                (intent["company_id"], intent["realm_id"], intent["environment"], provider_id)):
            identifiers.add(row[0]); mapped = True
    return identifiers, mapped


def links(connection, application, decrypt):
    applications, billing = modules()
    command, proposal_hash = application["receipt"]["commandID"], application["receipt"]["proposalSHA256"]
    source = applications.source.StaffWorkspaceSource(SimpleNamespace(decrypt=decrypt))
    for link in connection.execute("SELECT * FROM staff_invoice_application_publications WHERE command_id=?", (command,)):
        proof = source.decode(link["ciphertext"])
        if not isinstance(proof, dict) or set(proof) != set("schema commandID proposalSHA256 publicationID payloadHash companyID realmID environment invoiceID".split()):
            raise fail("storage_unavailable", "The original invoice publication link could not be verified.", 503)
        row = connection.execute("SELECT * FROM billing_publications WHERE id=?", (link["publication_id"],)).fetchone()
        if (row is None or proof["schema"] != "office-invoice-publication-v1" or proof["commandID"] != command
                or proof["proposalSHA256"] != proposal_hash or proof["publicationID"] != row["id"]
                or proof["payloadHash"] != row["payload_hash"] or row["document_type"] != "Invoice"
                or any(proof[key] != row[column] for key, column in (
                    ("companyID", "company_id"), ("realmID", "realm_id"), ("environment", "environment"), ("invoiceID", "local_document_id")))
                or row["company_id"] != application["receipt"]["companyID"] or row["local_document_id"] != application["receipt"]["invoiceID"]):
            raise fail("storage_unavailable", "The original invoice publication link could not be verified.", 503)
        billing.BillingPublisher.intent(SimpleNamespace(decrypt=decrypt), row)
        if row["state"] == "confirmed":
            mapping = connection.execute("""SELECT provider_id FROM billing_entity_mappings
                WHERE company_id=? AND realm_id=? AND environment=? AND document_type='Invoice' AND local_document_id=?""",
                (row["company_id"], row["realm_id"], row["environment"], row["local_document_id"])).fetchone()
            if mapping is None or mapping[0] != row["provider_id"]:
                raise fail("storage_unavailable", "The original accounting identity could not be verified.", 503)
        yield row


def reconciled(connection, application, intent, decrypt):
    intent = dict(intent)
    target = intent.get("invoice_qbo_id") or intent.get("document", {}).get("Id")
    return any(row["state"] == "confirmed" and row["provider_id"]
               and (row["realm_id"], row["environment"]) == (intent["realm_id"], intent["environment"])
               and (target is None or target == row["provider_id"])
               for row in links(connection, application, decrypt))


def catalog_boundary(connection, intent, decrypt, now):
    identifier = intent["local_item_id"]
    for application in saved_applications(connection, intent["company_id"], decrypt, now, prepared_only=True):
        proposal = application["proposal"]
        item_ids = {r["id"] for r in proposal["dependencies"] if r["kind"] == "item"}
        item_ids.add(proposal["request"]["line"]["itemID"])
        if identifier in item_ids:
            raise fail(message="Finish the approved invoice's original local and company-source save before publishing its catalog items.")


def financial_lines(connection, application, intent, *, current=None):
    applications, billing = modules()
    proposal = application["proposal"]
    invoice = current or dict(proposal["expectedInvoice"], fields=proposal["invoiceFields"])
    records = proposal["dependencies"] + [invoice]
    if proposal["newItemFields"] is not None:
        records.append(dict(invoice, kind="item", id=proposal["request"]["line"]["itemID"], fields=proposal["newItemFields"], revision=1))
    snapshot = applications.billing.Catalog(applications.ProposalGraph(records), invoice).read(applications.atom(invoice["fields"], "catalogSnapshotJSON"))
    def provider_id(local_id):
        row = connection.execute("""SELECT provider_id FROM catalog_entity_mappings
            WHERE company_id=? AND realm_id=? AND environment=? AND local_item_id=?""",
            (*billing.scope(intent), local_id.lower())).fetchone()
        if row is None:
            raise fail("invoice_application_changed", "Publish the original approved catalog item and retain its shared mapping first.")
        return row[0]
    def line(value):
        if "bundle" in value:
            original_scope = value["bundle"]["scope"]
            if dict(original_scope, companyID=original_scope["companyID"].lower()) != dict(companyID=intent["company_id"], realmID=intent["realm_id"], environment=intent["environment"]):
                raise fail("invoice_application_changed", "Use the original approved bundle's QuickBooks company.")
            return {"Amount": 0, "DetailType": "GroupLineDetail", "GroupLineDetail": {
                "GroupItemRef": {"value": provider_id(value["catalogItemID"])}, "Quantity": value["quantity"],
                "Line": [line(member["line"]) for member in value["bundle"]["members"]]}}
        return {"Amount": value["extendedAmount"], "DetailType": "SalesItemLineDetail", "SalesItemLineDetail": {
            "ItemRef": {"value": provider_id(value["catalogItemID"])}, "Qty": value["quantity"],
            "UnitPrice": value["unitPrice"], "TaxCodeRef": {"value": "TAX" if value["isTaxable"] else "NON"}}}
    result = [line(value) for value in snapshot["lines"]]
    if snapshot.get("discount"):
        discount = snapshot["discount"]
        gross = billing.gross_amount(result)
        amount = applications.billing.cents(gross * Decimal(str(discount["value"])) / 100) if discount["kind"] == "percentage" else Decimal(str(discount["value"]))
        detail = {"PercentBased": discount["kind"] == "percentage"}
        if detail["PercentBased"]:
            detail["DiscountPercent"] = discount["value"]
        result.append({"Amount": float(amount), "DetailType": "DiscountLineDetail", "DiscountLineDetail": detail})
    return billing.line_values(result)


def financial_signature(lines):
    # Descriptions may include newly mapped provider/system labels. Every
    # charge-bearing identity, order, quantity, price, tax choice and discount
    # must nevertheless match the exact approved sale.
    result = []
    for raw in lines:
        value = {key: content for key, content in raw.items() if key != "Description"}
        if value["DetailType"] == "GroupLineDetail":
            value["GroupLineDetail"] = dict(value["GroupLineDetail"], Line=financial_signature(value["GroupLineDetail"]["Line"]))
        result.append(value)
    return result


def billing_boundary(connection, intent, decrypt, now):
    if intent["document_type"] != "Invoice":
        return []
    ids, _ = invoice_aliases(connection, intent, intent["document"].get("Id"))
    pending = []
    for application in saved_applications(connection, intent["company_id"], decrypt, now, invoice_ids=ids):
        if application["receipt"]["state"] != "published":
            raise fail()
        if not reconciled(connection, application, intent, decrypt):
            pending.append(application)
    if not pending:
        return []
    if len({(p["receipt"]["environment"], p["receipt"]["replicaID"]) for p in pending}) != 1:
        raise fail("invoice_application_changed", "Resolve the original company workspace before publishing this invoice.")
    latest = max(pending, key=lambda p: p["proposal"]["expectedInvoice"]["revision"])
    request = latest["proposal"]["request"]
    protocol, _ = modules()
    scope = tuple(latest["receipt"][key] for key in protocol.lines.SCOPE.split()) + (protocol.contract.SCHEMA_VERSION,)
    service = protocol.StaffOwnerInvoiceApplications(SimpleNamespace(decrypt=decrypt, now=now))
    current = service.current(connection, scope, "invoice", request["invoiceID"])
    if (current is None or current["deleted"] or current["revision"] <= latest["proposal"]["expectedInvoice"]["revision"]
            or protocol.atom(current["fields"], "status") not in ("unpaid", "overdue")
            or protocol.atom(current["fields"], "finalizedAt") is not None
            or protocol.atom(current["fields"], "projectMilestoneID") is not None
            or protocol.atom(current["fields"], "milestoneDraftReceiptJSON") is not None
            or protocol.lines.identifier_field(current["fields"], "customer") != request["customerID"]
            or protocol.lines.identifier_field(current["fields"], "serviceCallID") != request["jobID"]):
        raise fail("invoice_application_changed", "Review the original approved invoice in the current company source.")
    approved = financial_signature(financial_lines(connection, latest, intent))
    original_provider = protocol.atom(latest["proposal"]["expectedInvoice"]["fields"], "quickBooksID")
    current_provider = protocol.atom(current["fields"], "quickBooksID")
    if any(provider and (intent["operation"] != "update" or intent["document"].get("Id") != provider)
           for provider in (original_provider, current_provider)):
        raise fail("invoice_application_changed", "Update the invoice's original QuickBooks identity; do not create a replacement.")
    if (intent["local_document_id"] != request["invoiceID"] or intent["local_customer_id"] != request["customerID"]
            or intent.get("service_call_id") != request["jobID"]
            or financial_signature(intent["document"]["Line"]) != approved
            or financial_signature(financial_lines(connection, latest, intent, current=current)) != approved):
        raise fail("invoice_application_changed", "Publish the complete approved invoice lines under their original customer, job and item identities.")
    return pending


def claim_publication(connection, row, intent, decrypt, now):
    pending = billing_boundary(connection, intent, decrypt, now)
    expected = {value["receipt"]["commandID"] for value in pending}
    if not exists(connection, "staff_invoice_application_publications"):
        if expected:
            raise fail("storage_unavailable", "Office invoice recovery storage needs review.", 503)
        return
    actual = {link[0] for link in connection.execute(
        "SELECT command_id FROM staff_invoice_application_publications WHERE publication_id=?", (row["id"],))}
    if actual != expected:
        raise fail("invoice_application_changed", "Recover the publication reserved for the original approved invoice.")
    # Reading each original application above also verifies every encrypted link.


def bind_publication(connection, row, applications, encrypt):
    for application in applications:
        receipt = application["receipt"]
        proof = dict(schema="office-invoice-publication-v1", commandID=receipt["commandID"], proposalSHA256=receipt["proposalSHA256"],
            publicationID=row["id"], payloadHash=row["payload_hash"], companyID=row["company_id"], realmID=row["realm_id"],
            environment=row["environment"], invoiceID=row["local_document_id"])
        protocol, _ = modules()
        ciphertext = protocol.source.StaffWorkspaceSource(SimpleNamespace(encrypt=encrypt)).encode(proof)
        connection.execute("INSERT INTO staff_invoice_application_publications VALUES (?,?,?)", (receipt["commandID"], row["id"], ciphertext))


def payment_boundary(connection, intent, decrypt, now):
    intent = dict(intent)
    ids, mapped = invoice_aliases(connection, intent, intent["invoice_qbo_id"])
    # Legacy unlinked provider IDs require examining original encrypted invoice
    # identities too. Never equate CloudKit development with QBO sandbox.
    protocol, _ = modules()
    for application in saved_applications(connection, intent["company_id"], decrypt, now, invoice_ids=ids if mapped else None):
        proposal = application["proposal"]
        if reconciled(connection, application, intent, decrypt):
            continue
        original_provider = protocol.atom(proposal["expectedInvoice"]["fields"], "quickBooksID")
        relevant = proposal["expectedInvoice"]["id"] in ids or original_provider == intent["invoice_qbo_id"]
        # An unacknowledged create may already exist at QBO without a shared
        # provider mapping. Do not collect against an unlinked guessed identity.
        ambiguous_create = not mapped and any(row["operation"] == "create" and row["state"] in ("sending", "unknown")
            for row in links(connection, application, decrypt))
        if relevant or ambiguous_create:
            raise fail(message="Finish the approved invoice's verified QuickBooks publication before collecting or refunding payment.")


def application_boundary(connection, proposal):
    """Reverse fence: an office claim cannot race an existing provider send."""
    protocol, _ = modules()
    company, invoice = proposal["companyID"], proposal["request"]["invoiceID"]
    provider = protocol.atom(proposal["expectedInvoice"]["fields"], "quickBooksID")
    if exists(connection, "billing_publications"):
        rows = connection.execute("""SELECT b.* FROM billing_publications b LEFT JOIN billing_entity_mappings m
            ON m.company_id=b.company_id AND m.realm_id=b.realm_id AND m.environment=b.environment
                AND m.document_type=b.document_type AND m.local_document_id=b.local_document_id
            WHERE b.company_id=? AND b.document_type='Invoice' AND (b.local_document_id=? OR m.provider_id=?)
                AND b.state IN ('reserved','sending','unknown')""", (company, invoice, provider)).fetchone()
        if rows:
            raise fail("invoice_provider_pending", "Recover or cancel the original unsent invoice publication before approving more field work.")
    if exists(connection, "payment_attempts") and connection.execute("""SELECT 1 FROM payment_attempts
            WHERE company_id=? AND (invoice_id=? OR invoice_qbo_id=?) AND state NOT IN ('cancelled','declined') LIMIT 1""",
            (company, invoice, provider)).fetchone():
        raise fail("invoice_payment_pending", "Review existing collections or refunds before changing this invoice.")
    item_ids = {r["id"] for r in proposal["dependencies"] if r["kind"] == "item"}
    item_ids.add(proposal["request"]["line"]["itemID"])
    if proposal["newItemFields"] is not None and exists(connection, "catalog_entity_mappings"):
        if connection.execute("SELECT 1 FROM catalog_entity_mappings WHERE company_id=? AND local_item_id=? LIMIT 1",
                (company, proposal["request"]["line"]["itemID"])).fetchone():
            raise fail("invoice_catalog_pending", "This new item identity already has a provider link. Recover the original item before approval.")
    if exists(connection, "catalog_publications"):
        for row in connection.execute("SELECT local_item_id,state FROM catalog_publications WHERE company_id=? AND state!='cancelled'", (company,)):
            if row["local_item_id"] in item_ids and (row["state"] in ("reserved", "sending", "unknown")
                    or (proposal["newItemFields"] is not None and row["local_item_id"] == proposal["request"]["line"]["itemID"])):
                raise fail("invoice_catalog_pending", "Recover the original catalog publication before approving this invoice request.")
