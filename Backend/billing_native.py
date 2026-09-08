"""Scoped native preparation and original-proposal review; no QBO writes.

Publication still uses BillingPublisher's single-use dispatch permit. These
read paths never grant a new write merely because a device lost its journal.
"""
from __future__ import annotations

import re
from datetime import date

try:
    from Backend import billing_publications as billing, billing_assignments as assignments
    from Backend.catalog_publications import canonical, failure, scope
    from Backend.payment_attempts import canonical_uuid, reference
except ModuleNotFoundError:
    import billing_publications as billing, billing_assignments as assignments
    from catalog_publications import canonical, failure, scope
    from payment_attempts import canonical_uuid, reference


def wire_request(intent, fingerprint):
    result = {key: intent[column] for key, column in (
        ("companyID", "company_id"), ("realmID", "realm_id"), ("environment", "environment"),
        ("documentType", "document_type"), ("localDocumentID", "local_document_id"),
        ("localCustomerID", "local_customer_id"), ("operation", "operation"), ("document", "document"))}
    result["connectionRevision"] = intent.get("connection_revision", assignments.connection_revision(fingerprint))
    for key, column in (("serviceCallID", "service_call_id"), ("assignmentRevision", "assignment_revision"), ("draftRevision", "draft_revision"),
                        ("projectMilestoneID", "project_milestone_id")):
        if column in intent:
            result[key] = intent[column]
    return result


class NativeBilling:
    def __init__(self, publisher):
        self.publisher = publisher

    def query(self, value):
        required = {"companyID", "realmID", "environment", "documentType", "localDocumentID", "localCustomerID"}
        shapes = (required, required | {"serviceCallID"}, required | {"serviceCallID", "projectMilestoneID"})
        if not isinstance(value, dict) or set(value) not in shapes or value.get("documentType") not in ("Invoice", "Estimate"):
            raise failure("invalid_query", "Choose the original saved billing document.", 400)
        intent = assignments.request_scope({**value, "serviceCallID": value.get("serviceCallID", value["localDocumentID"])})
        if "serviceCallID" not in value:
            intent.pop("service_call_id")
        intent.update(document_type=value["documentType"], local_document_id=canonical_uuid(value["localDocumentID"]),
                      local_customer_id=canonical_uuid(value["localCustomerID"]))
        if "projectMilestoneID" in value:
            if value["documentType"] != "Invoice":
                raise failure("invalid_query", "Milestone billing belongs to its original invoice.", 400)
            intent["project_milestone_id"] = canonical_uuid(value["projectMilestoneID"])
        return intent

    def inspect(self, connection, session, intent):
        p = self.publisher
        actor, fingerprint = p.assignments.context(connection, session, intent)
        office = billing.office_role(actor["role"], intent["document_type"])
        assignment = p.assignments.record(connection, intent) if intent.get("service_call_id") else None
        if assignment is not None and assignment["local_customer_id"] != intent["local_customer_id"]:
            raise failure("customer_changed", "Keep the original job's customer.")
        if not office:
            if (actor["role"] != "Field Technician" or not p.assignments.usable(connection, assignment, fingerprint)
                    or actor["email"] not in p.assignments.roster(assignment)):
                raise failure("access_denied", "Confirm current assignment to this job before publishing.", 403)
        binding = connection.execute("SELECT * FROM billing_job_documents WHERE company_id=? AND realm_id=? AND environment=? AND document_type=? AND local_document_id=?",
                                     billing.document_scope(intent)).fetchone()
        if binding and (binding["service_call_id"] != intent.get("service_call_id") or binding["local_customer_id"] != intent["local_customer_id"]):
            raise failure("job_changed", "Retain this document's original job and customer.")
        customer = connection.execute("SELECT provider_id FROM customer_entity_mappings WHERE company_id=? AND realm_id=? AND environment=? AND local_customer_id=?",
                                      (*scope(intent), intent["local_customer_id"])).fetchone()
        if customer is None:
            raise failure("customer_review", "Ask the office to review this customer's shared QuickBooks link.")
        mapping = connection.execute("SELECT * FROM billing_entity_mappings WHERE company_id=? AND realm_id=? AND environment=? AND document_type=? AND local_document_id=?",
                                     billing.document_scope(intent)).fetchone()
        if mapping and mapping["local_customer_id"] != intent["local_customer_id"]:
            raise failure("customer_changed", "Retain the mapped accounting document's customer.")
        if mapping and not office and binding is None:
            raise failure("access_denied", "Ask the office to confirm this existing document's original job.", 403)
        value = {"companyID": intent["company_id"], "realmID": intent["realm_id"], "environment": intent["environment"],
            "documentType": intent["document_type"], "localDocumentID": intent["local_document_id"], "localCustomerID": intent["local_customer_id"],
            "serviceCallID": intent.get("service_call_id"), "connectionRevision": assignments.connection_revision(fingerprint),
            "customerProviderID": customer[0], "providerID": mapping["provider_id"] if mapping else None,
            "authority": "office" if office else "assigned",
            "assignment": p.assignments.public(connection, assignment, fingerprint) if assignment else None}
        if "project_milestone_id" in intent:
            milestone_id = intent["project_milestone_id"]
            original = billing.billing_milestones.original(connection, p, intent, milestone_id)
            value["milestoneIdentityVersion"] = 1
            value["milestone"] = billing.billing_milestones.public(original, milestone_id) if original else None
        grant = dict(connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone())
        grant["grant_fingerprint"] = fingerprint
        return value, grant

    def context(self, session, query):
        intent = self.query(query)
        p = self.publisher
        with p.database() as connection:
            initial, grant = self.inspect(connection, session, intent)
        def check():
            with p.database() as connection:
                current, _ = self.inspect(connection, session, intent)
                if current != initial:
                    raise failure("context_changed", "The original billing context changed. Review it again.")
        remote = None
        if initial["providerID"]:
            provider = p.provider_factory(grant, check)
            remote = provider.read(intent["document_type"], initial["providerID"])
            check()
            self.validate_mapped(intent, initial, remote)
            remote = billing.public_document(remote)
        check()
        return {**initial, "document": remote}

    @staticmethod
    def validate_mapped(intent, context, remote):
        if not isinstance(remote, dict) or remote.get("Id") != context["providerID"] or billing.ref(remote.get("CustomerRef"))["value"] != context["customerProviderID"]:
            raise failure("identity_conflict", "QuickBooks did not confirm the original mapped document.")
        reference(remote.get("SyncToken"))
        try:
            posting_date = remote.get("TxnDate")
            if not isinstance(posting_date, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", posting_date):
                raise ValueError()
            date.fromisoformat(posting_date)
        except ValueError:
            raise failure("provider_unconfirmed", "Review the original accounting posting date.") from None
        lines = billing.provider_line_values(remote.get("Line"))
        tax_detail = remote.get("TxnTaxDetail")
        tax = billing.number(tax_detail.get("TotalTax") if isinstance(tax_detail, dict) else None)
        total = billing.number(remote.get("TotalAmt"))
        sold = billing.net_amount(lines)
        if sold < 0 or sold + tax != total or (intent["document_type"] == "Invoice" and billing.number(remote.get("Balance")) > total):
            raise failure("provider_unconfirmed", "Review the accounting total and balance.")
        if "CurrencyRef" in remote and billing.ref(remote["CurrencyRef"])["value"] != "USD":
            raise failure("provider_unconfirmed", "Review the accounting currency before linking this document.")
        notes = remote.get("PrivateNote", "")
        if not isinstance(notes, str):
            raise failure("provider_unconfirmed", "Review the accounting document's identity.")
        markers = [line.strip() for line in notes.splitlines() if line.strip().casefold().startswith(("gunnaire invoice id:", "gunnaire estimate id:"))]
        if markers and markers != [billing.marker(intent)]:
            raise failure("identity_conflict", "The accounting document identifies a different saved record.")

    def proposal(self, session, identifier):
        p = self.publisher
        with p.database() as connection:
            row = p.record(connection, identifier)
            actor = p.actor(connection, session)
            office = billing.office_role(actor["role"], row["document_type"])
            _, grant = p.authorize(connection, session, row, require_grant=not office, office_only=office)
            original = p.intent(row)
            author = connection.execute("SELECT role,is_active FROM users WHERE email=?", (row["actor_email"],)).fetchone()
            return {"publication": p.public(row), "proposal": wire_request(original, row["grant_fingerprint"]),
                    "connectionChanged": grant["grant_fingerprint"] != row["grant_fingerprint"],
                    "reviewableByOffice": bool(row["state"] == "reserved" and author and author["is_active"] and author["role"] == "Field Technician"
                                             and grant["grant_fingerprint"] == row["grant_fingerprint"])}

    def approve_original(self, session, identifier, payload):
        if not isinstance(payload, dict) or set(payload) != {"proposal"}:
            raise failure("invalid_request", "Confirm the exact displayed original proposal.", 400)
        supplied = billing.validated_request(payload["proposal"])
        p = self.publisher
        with p.database() as connection:
            row = p.record(connection, identifier)
            p.authorize(connection, session, row, office_only=True)
            if row["state"] != "reserved" or billing.digest(supplied) != row["payload_hash"]:
                raise failure("proposal_changed", "Only this exact never-sent proposal can be approved.")
            technician = row["actor_email"]
        # Existing approval validation rechecks the original grant, active
        # office role, technician and exact immutable proposal in its transaction.
        return {"id": p.approve_draft(session, payload["proposal"], technician, original_attempt=identifier)}
