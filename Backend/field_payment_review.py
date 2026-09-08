"""One invoice's shared, read-only accounting observation for field collection.

No charge, refund, accounting write, assignment completion or local-model receipt
is issued here. Accounting allocations are not bank-settlement evidence. A
collection limit is an observation, never a reservation or cross-app send permit.
"""
from __future__ import annotations

import re
import time
import unicodedata
from datetime import date, datetime, timezone

try:
    from Backend import payment_attempts as payments, billing_assignments
except ModuleNotFoundError:
    import payment_attempts as payments
    import billing_assignments


MAX_LINKED_PAYMENTS = 32
MAX_REVIEW_SECONDS = 60


def unconfirmed():
    return payments.AttemptError("provider_unconfirmed", "QuickBooks did not confirm this invoice's complete payment details.")


def provider_reference(value):
    try:
        return payments.reference(value)
    except payments.AttemptError:
        raise unconfirmed() from None


def posting_date(value):
    try:
        if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            raise ValueError()
        date.fromisoformat(value)
        return value
    except ValueError:
        raise unconfirmed() from None


def invoice_number(value):
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > 21 or any(unicodedata.category(c).startswith("C") for c in value):
        raise unconfirmed()
    return value.strip() or None


def linked_transactions(value, maximum=750):
    if not isinstance(value, list) or len(value) > maximum:
        raise unconfirmed()
    result = []
    for link in value:
        if not isinstance(link, dict):
            raise unconfirmed()
        pair = (provider_reference(link.get("TxnType")), provider_reference(link.get("TxnId")))
        if pair in result:
            raise unconfirmed()
        result.append(pair)
    return sorted(result)


def verify_identity(value, identifier, customer):
    if (not isinstance(value, dict) or value.get("Id") != identifier or value.get("status") in ("Deleted", "Voided")
            or not isinstance(value.get("CustomerRef"), dict) or value["CustomerRef"].get("value") != customer):
        raise unconfirmed()
    currency = value.get("CurrencyRef", {"value": "USD"})
    if not isinstance(currency, dict) or currency.get("value") != "USD":
        raise unconfirmed()


def invoice_projection(value, intent):
    verify_identity(value, intent["invoice_qbo_id"], intent["customer_qbo_id"])
    notes = value.get("PrivateNote", "")
    if not isinstance(notes, str):
        raise unconfirmed()
    markers = [line.strip() for line in notes.splitlines() if line.strip().casefold().startswith(("gunnaire invoice id:", "gunnaire estimate id:"))]
    if markers and markers != ["GunnAire invoice ID: " + intent["invoice_id"]]:
        raise payments.AttemptError("mapping_review", "The QuickBooks invoice identifies a different saved document. Ask Accounting to review its link.")
    total, balance = payments.money_cents(value.get("TotalAmt")), payments.money_cents(value.get("Balance"))
    if balance > total:
        raise unconfirmed()
    links = linked_transactions(value.get("LinkedTxn", []))
    identifiers = [identifier for kind, identifier in links if kind == "Payment"]
    if len(identifiers) > MAX_LINKED_PAYMENTS:
        raise payments.AttemptError("review_limit", "This invoice has extensive payment history. Accounting must review it in QuickBooks.")
    return {"invoiceNumber": invoice_number(value.get("DocNumber")), "syncToken": provider_reference(value.get("SyncToken")),
            "invoiceDate": posting_date(value.get("TxnDate")), "totalCents": total, "balanceCents": balance,
            "paymentIDs": identifiers, "links": links}


def payment_projection(value, identifier, intent):
    verify_identity(value, identifier, intent["customer_qbo_id"])
    total = payments.money_cents(value.get("TotalAmt"))
    unapplied = payments.money_cents(value.get("UnappliedAmt"))
    if unapplied > total:
        raise unconfirmed()
    lines = value.get("Line")
    if not isinstance(lines, list) or not 0 < len(lines) <= 750:
        raise unconfirmed()
    applied, adjustment, normalized = 0, False, []
    for line in lines:
        if not isinstance(line, dict):
            raise unconfirmed()
        amount = payments.money_cents(line.get("Amount"))
        links = linked_transactions(line.get("LinkedTxn"))
        # One amount with multiple destinations is not enough to establish an
        # invoice allocation. Never duplicate or guess an ambiguous amount.
        if len(links) != 1:
            raise unconfirmed()
        kind, target = links[0]
        if kind == "Invoice" and target == intent["invoice_qbo_id"]:
            applied += amount
        elif kind != "Invoice":
            adjustment = True
        normalized.append((kind, target, amount))
    if not 0 < applied <= payments.MAX_CENTS:
        raise unconfirmed()
    # Credit memos can fund invoice applications larger than TotalAmt (even a
    # zero-dollar Payment). Report the accounting application, not new cash.
    if not adjustment and sum(amount for _, _, amount in normalized) + unapplied != total:
        raise unconfirmed()
    public = {"paymentQuickBooksID": identifier, "syncToken": provider_reference(value.get("SyncToken")),
              "postingDate": posting_date(value.get("TxnDate")), "appliedCents": applied,
              "includesCreditOrAdjustment": adjustment}
    return public, (public, total, unapplied, sorted(normalized))


class FieldPaymentReview:
    def __init__(self, database, read_provider, audit, *, monotonic=time.monotonic, now=None):
        self.database, self.read_provider, self.audit = database, read_provider, audit
        self.monotonic, self.now = monotonic, now or (lambda: datetime.now(timezone.utc))
        self.journal = payments.PaymentAttemptJournal(database, None, None, None, audit, now=self.now)

    def context(self, session, query):
        required = {"companyID", "invoiceID", "localCustomerID", "invoiceQuickBooksID", "customerQuickBooksID"}
        if not isinstance(query, dict) or set(query) not in (required, required | {"serviceCallID"}):
            raise payments.AttemptError("invalid_query", "Choose the original saved business invoice.", 400)
        with self.database() as connection:
            self.journal.actor(connection, session)
            grant = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
            if grant is None:
                raise payments.AttemptError("provider_changed", "Ask an administrator to connect the business QuickBooks account.")
            scope = {**query, "realmID": grant["realm_id"], "environment": grant["environment"],
                     "connectionRevision": billing_assignments.connection_revision(payments.grant_fingerprint(grant))}
        self.inspect(session, self.query(scope))
        return scope

    @staticmethod
    def query(value):
        required = {"companyID", "realmID", "environment", "invoiceID", "localCustomerID",
                    "invoiceQuickBooksID", "customerQuickBooksID", "connectionRevision"}
        if (not isinstance(value, dict) or set(value) not in (required, required | {"serviceCallID"})
                or value.get("environment") not in ("sandbox", "production")
                or not isinstance(value.get("connectionRevision"), str)
                or re.fullmatch(r"[a-f0-9]{64}", value["connectionRevision"]) is None):
            raise payments.AttemptError("invalid_query", "Choose the original saved business invoice.", 400)
        return {"company_id": payments.canonical_uuid(value["companyID"]), "realm_id": payments.reference(value["realmID"]),
                "environment": value["environment"], "invoice_id": payments.canonical_uuid(value["invoiceID"]),
                "local_customer_id": payments.canonical_uuid(value["localCustomerID"]),
                "invoice_qbo_id": payments.reference(value["invoiceQuickBooksID"]),
                "customer_qbo_id": payments.reference(value["customerQuickBooksID"]),
                "connection_revision": value["connectionRevision"],
                "service_call_id": payments.canonical_uuid(value["serviceCallID"]) if "serviceCallID" in value else None,
                "kind": "charge", "amount_cents": 0}

    def inspect(self, session, intent):
        with self.database() as connection:
            # One consistent SQLite read snapshot; no network work holds it.
            connection.execute("BEGIN")
            actor = self.journal.authorize(connection, session, intent, recovery=True)
            grant = self.journal.connection_context(connection, intent)
            if billing_assignments.connection_revision(grant["grant_fingerprint"]) != intent["connection_revision"]:
                raise payments.AttemptError("grant_changed", "QuickBooks was reconnected. Reopen the original invoice.")
            scope = (intent["company_id"], intent["realm_id"], intent["environment"])
            customer = connection.execute("SELECT * FROM customer_entity_mappings WHERE company_id=? AND realm_id=? AND environment=? AND local_customer_id=?",
                                          (*scope, intent["local_customer_id"])).fetchone()
            mapping = connection.execute("SELECT * FROM billing_entity_mappings WHERE company_id=? AND realm_id=? AND environment=? AND document_type='Invoice' AND local_document_id=?",
                                         (*scope, intent["invoice_id"])).fetchone()
            if (customer is None or customer["provider_id"] != intent["customer_qbo_id"] or mapping is None
                    or mapping["provider_id"] != intent["invoice_qbo_id"] or mapping["local_customer_id"] != intent["local_customer_id"]):
                raise payments.AttemptError("mapping_review", "Ask Accounting to confirm this invoice and customer's shared QuickBooks links.")
            binding = connection.execute("SELECT * FROM billing_job_documents WHERE company_id=? AND realm_id=? AND environment=? AND document_type='Invoice' AND local_document_id=?",
                                         (*scope, intent["invoice_id"])).fetchone()
            if binding and (binding["service_call_id"] != intent["service_call_id"] or binding["local_customer_id"] != intent["local_customer_id"]):
                raise payments.AttemptError("job_changed", "Reopen the invoice from its original job and customer.")
            self.journal.billing_publication_boundary(connection, intent)
            attempts = [dict(row) for row in connection.execute("""SELECT id,state,amount_cents,kind,updated_at FROM payment_attempts
                WHERE company_id=? AND realm_id=? AND environment=? AND invoice_qbo_id=?
                  AND state IN ('reserved','sending','unknown','confirmed') ORDER BY id""", (*scope, intent["invoice_qbo_id"]))]
            assignment, allowance = None, payments.MAX_CENTS
            if actor["role"] == "Field Technician":
                assignment = dict(connection.execute("""SELECT * FROM field_payment_assignments
                    WHERE invoice_id=? COLLATE NOCASE ORDER BY created_at DESC,id DESC LIMIT 1""",
                    (intent["invoice_id"],)).fetchone())
                approver = connection.execute("SELECT role,is_active FROM users WHERE email=?", (assignment["assigned_by"],)).fetchone()
                if (assignment["assigned_to"] != actor["email"] or assignment["status"] not in ("pending", "accepted", "completed")
                        or approver is None or not approver["is_active"] or approver["role"] not in ("Admin", "Accounting", "Dispatcher")):
                    raise payments.AttemptError("assignment_required", "Ask the office to confirm your current collection assignment.", 403)
                verified = connection.execute("""SELECT COALESCE(SUM(amount_cents),0) FROM payment_attempts
                    WHERE company_id=? AND invoice_id=? AND actor_email=? AND kind='charge'
                      AND state IN ('confirmed','completed') AND created_at>=?""",
                    (intent["company_id"], intent["invoice_id"], actor["email"], assignment["created_at"])).fetchone()[0]
                allowance = max(0, payments.money_cents(assignment["amount"]) - max(verified, payments.money_cents(assignment["collected_amount"])))
                if assignment["status"] == "completed":
                    allowance = 0
            if attempts:
                allowance = 0
            snapshot = (actor["email"], actor["role"], grant["grant_fingerprint"], dict(mapping), dict(customer),
                        dict(binding) if binding else None, assignment, allowance, attempts)
            return snapshot, grant

    def review(self, session, query):
        intent = self.query(query)
        initial, grant = self.inspect(session, intent)
        started = self.monotonic()

        def check():
            if self.monotonic() - started > MAX_REVIEW_SECONDS:
                raise payments.AttemptError("review_timeout", "The payment check took too long. Refresh before collecting again.", 504)
            current, _ = self.inspect(session, intent)
            if current != initial:
                raise payments.AttemptError("review_changed", "Collection details changed during the check. Refresh before collecting again.")

        def read(category, identifier):
            check()
            value = self.read_provider(grant, category, identifier, authorize=check)
            check()
            return value

        original = invoice_projection(read("invoice", intent["invoice_qbo_id"]), intent)
        records, proofs = [], {}
        for identifier in original["paymentIDs"]:
            value, proof = payment_projection(read("accounting", identifier), identifier, intent)
            records.append(value)
            proofs[identifier] = proof
        # Re-read the same exact records and invoice; mixed versions never form
        # a successful observation. This still cannot lock QuickBooks or another
        # application, and must never be treated as permission to charge.
        for identifier in original["paymentIDs"]:
            _, proof = payment_projection(read("accounting", identifier), identifier, intent)
            if proof != proofs[identifier]:
                raise payments.AttemptError("review_changed", "A payment changed during the check. Refresh before collecting again.")
        if original != invoice_projection(read("invoice", intent["invoice_qbo_id"]), intent):
            raise payments.AttemptError("review_changed", "The invoice changed during the check. Refresh before collecting again.")
        if sum(record["appliedCents"] for record in records) > original["totalCents"] - original["balanceCents"]:
            raise unconfirmed()
        check()
        result = {key: value for key, value in query.items()}
        result.update(protocolVersion=1, serviceCallID=intent["service_call_id"],
                      **{key: value for key, value in original.items() if key not in ("links", "paymentIDs")},
                      observedAt=self.now().isoformat(), currency="USD", payments=records,
                      authority="office" if initial[1] in ("Admin", "Accounting") else "assigned",
                      hasOpenAttempt=bool(initial[-1]), collectionLimitCents=min(initial[-2], original["balanceCents"]),
                      fundsSettlementVerified=False)
        self.audit(initial[0], "review", "field-payment-review", intent["invoice_id"])
        check()
        return result
