"""One explicit QuickBooks document email per mapped document, across devices.

An uncertain send is never retried. A later provider read may show a matching
email but cannot attribute it to the original attempt or prove recipient delivery.
"""
from __future__ import annotations

import hashlib
import re
import sqlite3
import uuid
from datetime import datetime, timedelta, timezone

try:
    from Backend import billing_publications
    from Backend.payment_attempts import canonical_uuid, reference
except ModuleNotFoundError:
    import billing_publications
    from payment_attempts import canonical_uuid, reference


SCHEMA = """
CREATE TABLE IF NOT EXISTS qbo_document_email_attempts (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, realm_id TEXT NOT NULL,
 environment TEXT NOT NULL, document_type TEXT NOT NULL,
 local_document_id TEXT NOT NULL, provider_id TEXT NOT NULL,
 customer_provider_id TEXT NOT NULL, recipient_digest TEXT NOT NULL,
 grant_fingerprint TEXT NOT NULL, actor_email TEXT NOT NULL,
 previous_delivery_time TEXT, started_at TEXT NOT NULL,
 lease_until TEXT NOT NULL, state TEXT NOT NULL
 CHECK(state IN ('sending','unknown','observed','accepted')),
 updated_at TEXT NOT NULL,
 UNIQUE(company_id,realm_id,environment,document_type,provider_id)
);
"""


def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)


def recipient_address(value):
    if (not isinstance(value, str) or value != value.strip().lower() or len(value) > 254
            or not re.fullmatch(r"[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+", value)):
        raise billing_publications.failure("recipient_required", "Choose one verified customer email address.", 400)
    return value


def request_values(value):
    if not isinstance(value, dict) or set(value) != {
        "companyID", "realmID", "environment", "documentType", "providerID", "customerProviderID", "recipient"
    } or value.get("documentType") not in ("Estimate", "Invoice") or value.get("environment") not in ("sandbox", "production"):
        raise billing_publications.failure("invalid_request", "Choose one original QuickBooks document and recipient.", 400)
    return {
        "company_id": canonical_uuid(value["companyID"]),
        "realm_id": reference(value["realmID"]),
        "environment": value["environment"],
        "document_type": value["documentType"],
        "provider_id": reference(value["providerID"]),
        "customer_provider_id": reference(value["customerProviderID"]),
        "recipient": recipient_address(value["recipient"]),
    }


def stamp(value):
    if not isinstance(value, str):
        return None
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return result.astimezone(timezone.utc) if result.tzinfo else None
    except ValueError:
        return None


def observed(document, intent):
    if not isinstance(document, dict) or document.get("Id") != intent["provider_id"]:
        raise billing_publications.failure("provider_unconfirmed", "QuickBooks returned a different document.")
    customer = document.get("CustomerRef")
    if not isinstance(customer, dict) or customer.get("value") != intent["customer_provider_id"]:
        raise billing_publications.failure("customer_changed", "The QuickBooks document customer changed.")
    recipient = document.get("BillEmail")
    address = recipient.get("Address") if isinstance(recipient, dict) else None
    delivery = document.get("DeliveryInfo")
    return (address.strip().lower() if isinstance(address, str) else None,
            document.get("EmailStatus"), delivery if isinstance(delivery, dict) else {})


def confirms(document, intent, attempt):
    address, status, delivery = observed(document, intent)
    sent = stamp(delivery.get("DeliveryTime"))
    before = stamp(attempt["previous_delivery_time"]) if attempt["previous_delivery_time"] else None
    started = stamp(attempt["started_at"])
    return (address == intent["recipient"] and status == "EmailSent"
            and delivery.get("DeliveryType") == "Email" and sent is not None
            and started is not None and sent >= started and (before is None or sent > before))


class DocumentEmailJournal:
    def __init__(self, database, publisher, provider_factory, audit, now=None):
        self.database, self.publisher, self.provider_factory, self.audit = database, publisher, provider_factory, audit
        self.now = now or (lambda: datetime.now(timezone.utc))

    def context(self, connection, session_id, intent):
        mapping = connection.execute("""SELECT * FROM billing_entity_mappings WHERE
            company_id=? AND realm_id=? AND environment=? AND document_type=? AND provider_id=?""",
            (intent["company_id"], intent["realm_id"], intent["environment"], intent["document_type"], intent["provider_id"])).fetchone()
        if mapping is None:
            raise billing_publications.failure("mapping_required", "Review this saved document's original QuickBooks link before emailing.")
        customer = connection.execute("""SELECT provider_id FROM customer_entity_mappings WHERE
            company_id=? AND realm_id=? AND environment=? AND local_customer_id=?""",
            (intent["company_id"], intent["realm_id"], intent["environment"], mapping["local_customer_id"])).fetchone()
        if customer is None or customer["provider_id"] != intent["customer_provider_id"]:
            raise billing_publications.failure("customer_changed", "Review the original customer link before emailing.")
        synthetic = {**intent, "local_document_id": mapping["local_document_id"],
                     "local_customer_id": mapping["local_customer_id"], "operation": "update"}
        # The server has no authoritative customer-consent record. Field job
        # assignment cannot grant this direct email API. Native app flows check
        # consent, but an office caller can bypass that gate with direct HTTP;
        # this endpoint must not be enabled for release without server proof.
        actor, context = self.publisher.authorize(connection, session_id, synthetic,
                                                  require_grant=False, office_only=True)
        return actor, context, mapping

    def authorize(self, session_id, intent, *, expected_grant=None):
        with self.database() as connection:
            actor, context, mapping = self.context(connection, session_id, intent)
            if expected_grant is not None and context["grant_fingerprint"] != expected_grant:
                raise billing_publications.failure("grant_changed", "Review the original email attempt after reconnecting QuickBooks.")
            return actor, context, mapping

    def prior(self, connection, intent):
        return connection.execute("""SELECT * FROM qbo_document_email_attempts WHERE
            company_id=? AND realm_id=? AND environment=? AND document_type=? AND provider_id=?""",
            (intent["company_id"], intent["realm_id"], intent["environment"], intent["document_type"], intent["provider_id"])).fetchone()

    def run(self, session_id, request):
        intent = request_values(request)
        actor, context, _ = self.authorize(session_id, intent)
        with self.database() as connection:
            earlier = self.prior(connection, intent)
        if earlier is not None:
            return self.recover(session_id, intent, earlier)
        def check():
            self.authorize(session_id, intent, expected_grant=context["grant_fingerprint"])
        provider = self.provider_factory(context, check)
        customer = provider.read_customer(intent["customer_provider_id"])
        primary = customer.get("PrimaryEmailAddr")
        approved_address = primary.get("Address") if isinstance(primary, dict) else None
        if not isinstance(approved_address, str) or approved_address.strip().lower() != intent["recipient"]:
            raise billing_publications.failure("recipient_changed", "The QuickBooks customer email differs from the approved address.")
        before = provider.read(intent["document_type"], intent["provider_id"])
        address, status, delivery = observed(before, intent)
        if status == "EmailSent":
            raise billing_publications.failure("review_required", "QuickBooks already reports an email for this document. Review its history before another send.")
        if address is not None and address != intent["recipient"]:
            raise billing_publications.failure("recipient_changed", "The QuickBooks document email differs from the approved customer address.")
        if delivery.get("DeliveryTime") is not None and stamp(delivery["DeliveryTime"]) is None:
            raise billing_publications.failure("provider_unconfirmed", "QuickBooks returned an unreadable prior email time.")
        check()
        now = self.now().astimezone(timezone.utc)
        attempt_id = str(uuid.uuid4())
        digest = hashlib.sha256(intent["recipient"].encode()).hexdigest()
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            _, latest, mapping = self.context(connection, session_id, intent)
            if latest["grant_fingerprint"] != context["grant_fingerprint"]:
                raise billing_publications.failure("grant_changed", "Review after reconnecting QuickBooks.")
            previous = self.prior(connection, intent)
            if previous is not None:
                raise billing_publications.failure("review_required", "A staff device already started this email. Check its status before sending again.")
            connection.execute("""INSERT INTO qbo_document_email_attempts VALUES
                (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (attempt_id, intent["company_id"], intent["realm_id"], intent["environment"], intent["document_type"],
                 mapping["local_document_id"], intent["provider_id"], intent["customer_provider_id"], digest,
                 context["grant_fingerprint"], actor["email"], delivery.get("DeliveryTime"), now.isoformat(),
                 (now + timedelta(minutes=2)).isoformat(), "sending", now.isoformat()))
            self.audit(actor["email"], "dispatch", "qbo-document-email", attempt_id, connection=connection)
        try:
            check()
            response = provider.send(intent["document_type"], intent["provider_id"], intent["recipient"])
            with self.database() as connection:
                saved = self.prior(connection, intent)
            if not confirms(response, intent, saved):
                raise billing_publications.failure("provider_unconfirmed", "QuickBooks did not prove acceptance of this email.")
            check()
            with self.database() as connection:
                connection.execute("UPDATE qbo_document_email_attempts SET state='accepted',updated_at=? WHERE id=? AND state='sending'",
                                   (self.now().isoformat(), attempt_id))
                self.audit(actor["email"], "accepted", "qbo-document-email", attempt_id, connection=connection)
            return {"state": "accepted", "document": {intent["document_type"]: response}}
        except Exception:
            with self.database() as connection:
                connection.execute("UPDATE qbo_document_email_attempts SET state='unknown',updated_at=? WHERE id=? AND state='sending'",
                                   (self.now().isoformat(), attempt_id))
            raise billing_publications.failure("review_required", "QuickBooks may have accepted this email. Check the original attempt; no new copy was sent.") from None

    def recover(self, session_id, intent, attempt):
        if attempt["recipient_digest"] != hashlib.sha256(intent["recipient"].encode()).hexdigest():
            raise billing_publications.failure("recipient_changed", "The original email used another recipient. Review it in QuickBooks.")
        actor, context, _ = self.authorize(session_id, intent, expected_grant=attempt["grant_fingerprint"])
        if attempt["state"] == "accepted":
            return {"state": "reconciled"}
        if attempt["state"] == "observed":
            return {"state": "observed"}
        provider = self.provider_factory(context, lambda: self.authorize(session_id, intent, expected_grant=attempt["grant_fingerprint"]))
        document = provider.read(intent["document_type"], intent["provider_id"])
        if not confirms(document, intent, attempt):
            raise billing_publications.failure("review_required", "QuickBooks has not shown a matching later email. No new copy was sent.")
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            self.context(connection, session_id, intent)
            connection.execute("UPDATE qbo_document_email_attempts SET state='observed',updated_at=? WHERE id=? AND state IN ('sending','unknown')",
                               (self.now().isoformat(), attempt["id"]))
            self.audit(actor["email"], "matching-email-observed", "qbo-document-email", attempt["id"], connection=connection)
        return {"state": "observed"}
