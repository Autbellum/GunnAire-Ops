"""Derived milestone identity index; never a grant to create accounting data.

The encrypted original publication remains authoritative. Indexing old proposals
does not rewrite their hashes, invoice UUIDs, dates, payments or attachments.
Reservation/dispatch callers hold BEGIN IMMEDIATE so different offline invoice
UUIDs cannot acquire two dispatch permits for one business milestone.
"""
from __future__ import annotations

import re

try:
    from Backend.catalog_publications import failure, scope
    from Backend.payment_attempts import canonical_uuid
except ModuleNotFoundError:
    from catalog_publications import failure, scope
    from payment_attempts import canonical_uuid


SCHEMA = """
CREATE TABLE IF NOT EXISTS billing_milestone_index (
 publication_id TEXT PRIMARY KEY REFERENCES billing_publications(id),
 payload_hash TEXT NOT NULL, milestone_id TEXT
);
CREATE INDEX IF NOT EXISTS billing_milestone_lookup ON billing_milestone_index(milestone_id);
"""


def from_note(note):
    if note is None:
        return None
    if not isinstance(note, str):
        raise failure("milestone_review", "Review the original milestone reference.")
    found, kinds = [], set()
    for line in note.splitlines():
        line = line.strip()
        lower = line.casefold()
        kind = next((prefix for prefix in ("gunnaire milestone id:", "gunnaire project billing:") if lower.startswith(prefix)), None)
        if kind is None:
            continue
        pattern = (r"GunnAire Milestone ID: ([0-9a-fA-F-]{36})" if kind == "gunnaire milestone id:"
                   else r"GunnAire project billing: .+; milestone ID ([0-9a-fA-F-]{36})")
        match = re.fullmatch(pattern, line)
        if match is None or kind in kinds:
            raise failure("milestone_review", "Keep one complete original milestone reference.")
        kinds.add(kind)
        found.append(canonical_uuid(match[1]))
    if len(set(found)) > 1:
        raise failure("milestone_review", "The saved milestone references disagree.")
    return found[0] if found else None


def identity(intent):
    saved = intent.get("project_milestone_id")
    noted = from_note(intent["document"].get("PrivateNote"))
    if saved is not None:
        saved = canonical_uuid(saved)
        if noted is not None and saved != noted:
            raise failure("milestone_review", "Keep the original milestone on this invoice.")
    value = saved or noted
    if value is not None and (intent["document_type"] != "Invoice" or (saved is not None and not intent.get("service_call_id"))):
        raise failure("milestone_review", "Keep milestone billing with its original job and invoice.")
    return value


def index_row(connection, publisher, row):
    value = identity(publisher.intent(row))
    connection.execute("INSERT OR IGNORE INTO billing_milestone_index VALUES (?,?,?)",
                       (row["id"], row["payload_hash"], value))


def history(connection, publisher, intent, milestone_id):
    # Only the first lookup decodes historical proposals. Non-milestone rows
    # receive a NULL index entry too, avoiding repeated whole-history scans.
    parameters = scope(intent)
    predicate = ""
    if milestone_id is None:
        predicate = " AND p.local_document_id=?"
        parameters += (intent["local_document_id"],)
    rows = connection.execute("""SELECT p.* FROM billing_publications p
        LEFT JOIN billing_milestone_index i ON i.publication_id=p.id
        WHERE p.company_id=? AND p.realm_id=? AND p.environment=? AND p.document_type='Invoice'
        AND i.publication_id IS NULL""" + predicate, parameters)
    for row in rows:
        index_row(connection, publisher, row)
    return connection.execute("""SELECT p.*,i.milestone_id,i.payload_hash AS indexed_hash
        FROM billing_publications p JOIN billing_milestone_index i ON i.publication_id=p.id
        WHERE p.company_id=? AND p.realm_id=? AND p.environment=? AND p.document_type='Invoice'
        AND (i.milestone_id=? OR p.local_document_id=?)
        ORDER BY p.created_at DESC,p.id DESC""", (*scope(intent), milestone_id, intent["local_document_id"])).fetchall()


def original(connection, publisher, intent, milestone_id):
    rows = history(connection, publisher, intent, milestone_id)
    relevant = []
    for row in rows:
        source = publisher.intent(row)
        actual = identity(source)
        if actual != row["milestone_id"] or row["payload_hash"] != row["indexed_hash"]:
            raise failure("storage_unavailable", "The original milestone index could not be verified.", 503)
        if actual is not None or milestone_id is not None:
            if actual != milestone_id:
                raise failure("milestone_review", "This invoice must keep its original milestone reference.")
            if source["local_customer_id"] != intent["local_customer_id"] or source.get("service_call_id") != intent.get("service_call_id"):
                raise failure("milestone_review", "Keep the milestone's original customer and job.")
            if row["local_document_id"] == intent["local_document_id"] and row["state"] in ("sending", "unknown", "confirmed") and "document" in intent:
                locked = ("Line", "CustomerRef", "TxnDate", "ShipAddr", "ShipFromAddr", "ApplyTaxAfterDiscount", "CurrencyRef")
                if any(source["document"].get(key) != intent["document"].get(key) for key in locked):
                    raise failure("milestone_allocation_changed", "Keep the milestone's originally issued items, prices, posting date and tax addresses. Ask accounting to reconcile changes.")
            relevant.append(row)
    if len({row["local_document_id"] for row in relevant}) > 1:
        raise failure("milestone_history_conflict", "More than one saved invoice already identifies this milestone. Ask accounting to reconcile the originals.")
    return relevant[0] if relevant else None


def ensure(connection, publisher, intent):
    if intent["document_type"] != "Invoice":
        return
    value = identity(intent)
    row = original(connection, publisher, intent, value)
    if row is not None and row["local_document_id"] != intent["local_document_id"]:
        raise failure("milestone_original", "Another device already saved this milestone's original invoice. Open Billing Review to find it; keep this local draft.")


def public(row, milestone_id):
    return {"projectMilestoneID": milestone_id, "localDocumentID": row["local_document_id"],
            "localCustomerID": row["local_customer_id"], "publicationID": row["id"], "state": row["state"]}
