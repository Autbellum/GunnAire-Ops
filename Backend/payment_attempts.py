"""Durable, company-scoped payment coordination.

This module never sends a charge/refund. It issues exactly one dispatch permit,
then requires a server-side provider read before accepting an outcome. An
uncertain or abandoned dispatch is never automatically released or replayed.
Only opaque references, amounts and safe provider evidence are persisted.
"""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import uuid
from datetime import datetime, timezone
from decimal import Decimal, DecimalException, InvalidOperation


MAX_CENTS = 100_000_000  # Existing field-collection business limit: USD 1,000,000.
REFERENCE = re.compile(r"[A-Za-z0-9._:-]{1,128}")
OPEN_STATES = ("reserved", "sending", "unknown", "confirmed")
SCHEMA = """
CREATE TABLE IF NOT EXISTS payment_attempts (
    id TEXT PRIMARY KEY,
    company_id TEXT NOT NULL,
    realm_id TEXT NOT NULL,
    environment TEXT NOT NULL,
    grant_fingerprint TEXT NOT NULL,
    invoice_id TEXT NOT NULL,
    invoice_qbo_id TEXT NOT NULL,
    customer_qbo_id TEXT NOT NULL,
    amount_cents INTEGER NOT NULL CHECK(amount_cents > 0),
    rail TEXT NOT NULL CHECK(rail IN ('card','ach')),
    kind TEXT NOT NULL CHECK(kind IN ('charge','refund')),
    source_payment_id TEXT,
    source_provider_id TEXT,
    source_accounting_id TEXT,
    intent_hash TEXT NOT NULL,
    request_id TEXT NOT NULL UNIQUE,
    client_transaction_id TEXT NOT NULL UNIQUE,
    actor_email TEXT NOT NULL,
    actor_session_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('reserved','sending','unknown','confirmed','completed','cancelled','declined')),
    provider_id TEXT,
    candidate_provider_id TEXT,
    provider_status TEXT,
    accounting_id TEXT,
    created_at TEXT NOT NULL,
    submitted_at TEXT,
    confirmed_at TEXT,
    completed_at TEXT,
    updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS one_open_payment_attempt_per_invoice
    ON payment_attempts(company_id, realm_id, environment, invoice_qbo_id)
    WHERE state IN ('reserved','sending','unknown','confirmed');
CREATE UNIQUE INDEX IF NOT EXISTS unique_attempt_provider_evidence
    ON payment_attempts(company_id, realm_id, environment, rail, kind, provider_id)
    WHERE provider_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS payment_invoice_limits (
    company_id TEXT NOT NULL,
    realm_id TEXT NOT NULL,
    environment TEXT NOT NULL,
    invoice_qbo_id TEXT NOT NULL,
    balance_ceiling_cents INTEGER NOT NULL CHECK(balance_ceiling_cents >= 0),
    updated_at TEXT NOT NULL,
    PRIMARY KEY(company_id, realm_id, environment, invoice_qbo_id)
);
"""


class AttemptError(Exception):
    def __init__(self, code: str, message: str, status: int = 409):
        super().__init__(message)
        self.code = code
        self.status = status


def canonical_uuid(value):
    if not isinstance(value, str):
        raise AttemptError("invalid_request", "A valid operation, company and invoice identity is required.", 400)
    try:
        normalized = str(uuid.UUID(value))
    except ValueError:
        raise AttemptError("invalid_request", "A valid operation, company and invoice identity is required.", 400) from None
    if value.lower() != normalized:
        raise AttemptError("invalid_request", "Use canonical UUID identities.", 400)
    return normalized


def reference(value):
    if not isinstance(value, str) or value in (".", "..") or REFERENCE.fullmatch(value) is None:
        raise AttemptError("invalid_reference", "A valid QuickBooks record reference is required.", 400)
    return value


def money_cents(value):
    if isinstance(value, bool) or not isinstance(value, (str, int, float, Decimal)):
        raise AttemptError("invalid_amount", "The provider amount could not be verified.")
    try:
        if len(str(value)) > 64:
            raise InvalidOperation
        amount = Decimal(str(value))
        if not amount.is_finite() or not 0 <= amount <= MAX_CENTS // 100:
            raise InvalidOperation
        cents = amount * 100
        if not cents.is_finite() or cents != cents.to_integral_value() or not 0 <= cents <= MAX_CENTS:
            raise InvalidOperation
        return int(cents)
    except (DecimalException, ValueError, OverflowError):
        raise AttemptError("invalid_amount", "The provider amount could not be verified.") from None


def reference_value(payload, key):
    value = payload.get(key) if isinstance(payload, dict) else None
    return value.get("value") if isinstance(value, dict) else None


def grant_fingerprint(row):
    # Refresh rotation does not change a grant. An authorization exchange does.
    evidence = [row["realm_id"], row["environment"], row["client_id_fingerprint"], row["authorized_at"]]
    return hashlib.sha256(json.dumps(evidence, separators=(",", ":")).encode()).hexdigest()


def initialize_schema(connection):
    # Do not use executescript: it would commit a caller's migration transaction.
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)


class PaymentAttemptJournal:
    def __init__(self, database, read_invoice, read_transaction, read_accounting, audit, now=None):
        self.database = database
        self.read_invoice = read_invoice
        self.read_transaction = read_transaction
        self.read_accounting = read_accounting
        self.audit = audit
        self.now = now or (lambda: datetime.now(timezone.utc))

    def timestamp(self):
        return self.now().isoformat()

    def actor(self, connection, session_id):
        row = connection.execute(
            """SELECT s.*, u.role, u.is_active FROM auth_sessions s
               JOIN users u ON u.email = s.email WHERE s.id = ?""", (session_id,),
        ).fetchone()
        if row is None or row["revoked_at"] is not None or not row["is_active"]:
            raise AttemptError("session_required", "Sign in again before collecting a payment.", 403)
        try:
            expiry = datetime.fromisoformat(row["expires_at"].replace("Z", "+00:00"))
            issued = datetime.fromisoformat(row["created_at"].replace("Z", "+00:00"))
            valid = expiry.tzinfo is not None and issued.tzinfo is not None and issued <= self.now() < expiry
        except (ValueError, TypeError):
            valid = False
        if not valid or row["role"] not in ("Admin", "Accounting", "Field Technician"):
            raise AttemptError("collection_access_required", "Current payment-collection access is required.", 403)
        return row

    def authorize(self, connection, session_id, intent, *, ownership=False, recovery=False):
        actor = self.actor(connection, session_id)
        company = connection.execute("SELECT company_id FROM company_identity WHERE singleton = 1").fetchone()
        if company is None or company["company_id"] != intent["company_id"]:
            raise AttemptError("company_changed", "The business workspace changed. Reopen the invoice.", 403)
        if actor["role"] == "Field Technician":
            if intent["kind"] != "charge":
                raise AttemptError("refund_access_required", "An administrator or accountant must review refunds.", 403)
            assignment = connection.execute(
                """SELECT * FROM field_payment_assignments
                   WHERE invoice_id = ? COLLATE NOCASE AND assigned_to = ?
                   ORDER BY created_at DESC LIMIT 1""",
                (intent["invoice_id"], actor["email"]),
            ).fetchone()
            allowed = ("pending", "accepted", "completed") if recovery else ("pending", "accepted")
            if assignment is None or assignment["status"] not in allowed:
                raise AttemptError("assignment_required", "This invoice has no active collection assignment for you.", 403)
            verified = connection.execute(
                """SELECT COALESCE(SUM(amount_cents),0) FROM payment_attempts
                   WHERE company_id=? AND invoice_id=? AND actor_email=? AND kind='charge'
                   AND state IN ('confirmed','completed') AND created_at>=?""",
                (intent["company_id"], intent["invoice_id"], actor["email"], assignment["created_at"]),
            ).fetchone()[0]
            # Queue upload can lag provider/accounting completion. Do not let
            # that delay reopen a technician's already-consumed allowance.
            collected = max(money_cents(assignment["collected_amount"]), verified)
            remaining = money_cents(assignment["amount"]) - collected
            if not recovery and intent["amount_cents"] > remaining:
                raise AttemptError("assignment_limit", "The amount exceeds your assigned collection balance.", 403)
        if ownership and actor["role"] == "Field Technician" and intent["actor_email"] != actor["email"]:
            raise AttemptError("attempt_owner", "An office user must review another collector's attempt.", 403)
        return actor

    def connection_context(self, connection, intent, *, require_grant=False):
        row = connection.execute("SELECT * FROM qbo_connections WHERE id = 1").fetchone()
        if row is None or row["realm_id"] != intent["realm_id"] or row["environment"] != intent["environment"]:
            raise AttemptError("provider_changed", "Reconnect the original QuickBooks company before reviewing this payment.")
        fingerprint = grant_fingerprint(row)
        if require_grant and fingerprint != intent["grant_fingerprint"]:
            raise AttemptError("grant_changed", "QuickBooks was reconnected. Review the original payment before proceeding.")
        return {**dict(row), "grant_fingerprint": fingerprint}

    def intent(self, payload):
        required = {"id", "companyID", "realmID", "environment", "invoiceID", "invoiceQuickBooksID",
                    "customerQuickBooksID", "amountCents", "rail", "kind"}
        optional = {"sourcePaymentID", "sourceProviderID", "sourceAccountingID"}
        if not isinstance(payload, dict) or set(payload) - required - optional or not required <= set(payload):
            raise AttemptError("invalid_request", "Use the supported payment-attempt fields only.", 400)
        amount = payload["amountCents"]
        if type(amount) is not int or not 0 < amount <= MAX_CENTS:
            raise AttemptError("invalid_amount", "Enter a positive amount within the approved collection limit.", 400)
        if payload["rail"] not in ("card", "ach") or payload["kind"] not in ("charge", "refund") or payload["environment"] not in ("sandbox", "production"):
            raise AttemptError("invalid_request", "The payment type or environment is invalid.", 400)
        result = {
            "id": canonical_uuid(payload["id"]), "company_id": canonical_uuid(payload["companyID"]),
            "realm_id": reference(payload["realmID"]), "environment": payload["environment"],
            "invoice_id": canonical_uuid(payload["invoiceID"]),
            "invoice_qbo_id": reference(payload["invoiceQuickBooksID"]),
            "customer_qbo_id": reference(payload["customerQuickBooksID"]),
            "amount_cents": amount, "rail": payload["rail"], "kind": payload["kind"],
            "source_payment_id": None, "source_provider_id": None, "source_accounting_id": None,
        }
        if result["kind"] == "refund":
            result.update(
                source_payment_id=canonical_uuid(payload.get("sourcePaymentID")),
                source_provider_id=reference(payload.get("sourceProviderID")),
                source_accounting_id=reference(payload.get("sourceAccountingID")),
            )
        elif any(payload.get(key) is not None for key in optional):
            raise AttemptError("invalid_request", "A charge must not contain refund references.", 400)
        result["intent_hash"] = hashlib.sha256(json.dumps(result, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        return result

    @staticmethod
    def public(row):
        # Never return stored session IDs, grant fingerprints, tokens or raw payloads.
        fields = {
            "id": "id", "companyID": "company_id", "realmID": "realm_id", "environment": "environment",
            "invoiceID": "invoice_id", "invoiceQuickBooksID": "invoice_qbo_id",
            "customerQuickBooksID": "customer_qbo_id", "amountCents": "amount_cents",
            "rail": "rail", "kind": "kind", "state": "state", "requestID": "request_id",
            "clientTransactionID": "client_transaction_id", "providerID": "provider_id",
            "candidateProviderID": "candidate_provider_id",
            "providerStatus": "provider_status", "accountingID": "accounting_id",
            "sourcePaymentID": "source_payment_id", "sourceProviderID": "source_provider_id",
            "sourceAccountingID": "source_accounting_id",
            "createdAt": "created_at", "updatedAt": "updated_at",
        }
        return {out: row[key] for out, key in fields.items()}

    def event(self, connection, actor, action, attempt_id):
        self.audit(actor["email"], action, "payment-attempt", attempt_id, connection=connection)

    @staticmethod
    def row(connection, attempt_id):
        row = connection.execute("SELECT * FROM payment_attempts WHERE id = ?", (canonical_uuid(attempt_id),)).fetchone()
        if row is None:
            raise AttemptError("not_found", "The payment attempt was not found.", 404)
        return row

    def reserve(self, session_id, payload):
        intent = self.intent(payload)
        # Preauthorize before provider reads; then recheck inside the write
        # transaction after network suspension. Network I/O never holds DB locks.
        with self.database() as connection:
            self.authorize(connection, session_id, intent)
            context = self.connection_context(connection, intent)
            existing = connection.execute("SELECT * FROM payment_attempts WHERE id = ?", (intent["id"],)).fetchone()
            if existing is not None:
                if existing["intent_hash"] != intent["intent_hash"]:
                    raise AttemptError("identity_conflict", "This payment identity already has different details.")
                self.authorize(connection, session_id, existing, ownership=True)
                return self.public(existing)
        balance = self.verified_invoice_balance(context, intent)
        source_amount = self.verify_refund_source(context, intent) if intent["kind"] == "refund" else None
        return self.commit_reservation(session_id, intent, context, balance, source_amount)

    def verified_invoice_balance(self, context, intent):
        invoice = self.read_invoice(context, intent["invoice_qbo_id"])
        if not isinstance(invoice, dict) or invoice.get("Id") != intent["invoice_qbo_id"] or reference_value(invoice, "CustomerRef") != intent["customer_qbo_id"]:
            raise AttemptError("invoice_mismatch", "The QuickBooks invoice and customer could not be verified.")
        currency = reference_value(invoice, "CurrencyRef") if "CurrencyRef" in invoice else "USD"
        if currency != "USD":
            raise AttemptError("currency_mismatch", "Only verified USD invoices can use this collection workflow.")
        return money_cents(invoice.get("Balance"))

    def commit_reservation(self, session_id, intent, context, balance, source_amount):
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor = self.authorize(connection, session_id, intent)
            now_context = self.connection_context(connection, {**intent, "grant_fingerprint": context["grant_fingerprint"]}, require_grant=True)
            existing = connection.execute("SELECT * FROM payment_attempts WHERE id = ?", (intent["id"],)).fetchone()
            if existing is not None:
                if existing["intent_hash"] != intent["intent_hash"]:
                    raise AttemptError("identity_conflict", "This payment identity already has different details.")
                self.authorize(connection, session_id, existing, ownership=True)
                return self.public(existing)
            self.billing_publication_boundary(connection, intent)
            scope = (intent["company_id"], intent["realm_id"], intent["environment"], intent["invoice_qbo_id"])
            active = connection.execute(
                """SELECT id FROM payment_attempts WHERE company_id = ? AND realm_id = ?
                   AND environment = ? AND invoice_qbo_id = ? AND state IN ('reserved','sending','unknown','confirmed')""", scope,
            ).fetchone()
            if active is not None:
                raise AttemptError("payment_needs_review", "Another collection or refund is open for this invoice. Review it before sending another payment.")
            if source_amount is not None:
                self.check_refund_limit(connection, intent, source_amount)
            limit = connection.execute(
                """SELECT balance_ceiling_cents FROM payment_invoice_limits
                   WHERE company_id = ? AND realm_id = ? AND environment = ? AND invoice_qbo_id = ?""", scope,
            ).fetchone()
            accepted = connection.execute(
                """SELECT 1 FROM payment_attempts WHERE company_id=? AND realm_id=?
                   AND environment=? AND invoice_qbo_id=? AND kind='charge'
                   AND state IN ('confirmed','completed') LIMIT 1""", scope,
            ).fetchone()
            ceiling = min(balance, limit["balance_ceiling_cents"]) if limit and accepted else balance
            if intent["kind"] == "charge" and intent["amount_cents"] > ceiling:
                raise AttemptError("balance_exceeded", "The amount exceeds the verified remaining invoice balance.")
            now = self.timestamp()
            connection.execute(
                """INSERT INTO payment_invoice_limits VALUES (?, ?, ?, ?, ?, ?)
                   ON CONFLICT(company_id, realm_id, environment, invoice_qbo_id)
                   DO UPDATE SET balance_ceiling_cents = excluded.balance_ceiling_cents,
                                 updated_at = excluded.updated_at""", (*scope, ceiling, now),
            )
            fields = {**intent, "grant_fingerprint": now_context["grant_fingerprint"],
                      "request_id": str(uuid.uuid4()), "client_transaction_id": "ga-" + intent["kind"] + "-" + intent["id"],
                      "actor_email": actor["email"], "actor_session_id": session_id,
                      "state": "reserved", "created_at": now, "updated_at": now}
            columns = list(fields)
            connection.execute(
                "INSERT INTO payment_attempts (" + ",".join(columns) + ") VALUES (" + ",".join("?" for _ in columns) + ")",
                tuple(fields[key] for key in columns),
            )
            self.event(connection, actor, "reserve", intent["id"])
            return self.public(self.row(connection, intent["id"]))

    @staticmethod
    def billing_publication_boundary(connection, intent):
        # Both journals acquire BEGIN IMMEDIATE before checking and reserving.
        # Match provider identity too: a duplicate native UUID must not bypass
        # the invoice-update/collection exclusion. No provider call holds a lock.
        active = connection.execute("""SELECT 1 FROM billing_publications b
            LEFT JOIN billing_entity_mappings m ON m.company_id=b.company_id AND m.realm_id=b.realm_id
                AND m.environment=b.environment AND m.document_type=b.document_type AND m.local_document_id=b.local_document_id
            WHERE b.company_id=? AND b.realm_id=? AND b.environment=? AND b.document_type='Invoice'
                AND (b.local_document_id=? OR m.provider_id=?) AND b.state IN ('reserved','sending','unknown') LIMIT 1""",
            (intent["company_id"], intent["realm_id"], intent["environment"], intent["invoice_id"], intent["invoice_qbo_id"])).fetchone()
        if active:
            raise AttemptError("billing_needs_review", "Finish or review the original invoice sync before collecting or refunding payment.")

    def verify_refund_source(self, context, intent):
        source = self.read_transaction(context, "charge", intent["rail"], None, intent["source_provider_id"])
        expected_client = "ga-charge-" + intent["source_payment_id"]
        source_context = source.get("context") if isinstance(source, dict) else None
        if not isinstance(source, dict) or source.get("id") != intent["source_provider_id"] or not isinstance(source_context, dict) or source_context.get("clientTransID") != expected_client:
            raise AttemptError("refund_source_mismatch", "The original provider payment identity could not be verified.")
        if money_cents(source.get("amount")) < intent["amount_cents"]:
            raise AttemptError("refund_limit", "The refund exceeds the original provider payment.")
        currency = source.get("currency", "USD" if intent["rail"] == "ach" else None)
        allowed = ("CAPTURED",) if intent["rail"] == "card" else ("SUCCEEDED", "SETTLED")
        if currency != "USD" or source.get("status") not in allowed:
            raise AttemptError("refund_source_unconfirmed", "Verify the original payment's currency and settled or captured funds before refunding.")
        accounting = self.read_accounting(context, "charge", intent["source_accounting_id"])
        if not isinstance(accounting, dict) or accounting.get("Id") != intent["source_accounting_id"]:
            raise AttemptError("refund_source_mismatch", "The original accounting payment identity could not be verified.")
        self.verify_accounting(accounting, {**intent, "id": intent["source_payment_id"],
                               "kind": "charge", "amount_cents": money_cents(source.get("amount"))})
        # Intuit must still authorize remaining refundable funds. Legacy external
        # refunds are not inferred from incomplete local payment history.
        return money_cents(source.get("amount"))

    def check_refund_limit(self, connection, intent, source_amount):
        prior = connection.execute(
            """SELECT COALESCE(SUM(amount_cents),0) FROM payment_attempts WHERE company_id=?
               AND realm_id=? AND environment=? AND source_provider_id=? AND rail=?
               AND kind='refund' AND id<>? AND state IN ('reserved','sending','unknown','confirmed','completed')""",
            (intent["company_id"], intent["realm_id"], intent["environment"],
             intent["source_provider_id"], intent["rail"], intent["id"]),
        ).fetchone()[0]
        if prior + intent["amount_cents"] > source_amount:
            raise AttemptError("refund_limit", "Prior or unfinished refunds leave insufficient refundable funds.")

    def begin(self, session_id, attempt_id):
        with self.database() as connection:
            initial = dict(self.row(connection, attempt_id))
            self.authorize(connection, session_id, initial, ownership=True)
            context = self.connection_context(connection, initial, require_grant=True)
            if initial["state"] != "reserved":
                raise AttemptError("dispatch_already_started", "This payment may already have been sent. Reconcile the original attempt; do not send it again.")
        # Reservation/tokenization can span minutes. Refresh financial evidence
        # before granting dispatch, without holding the database lock over I/O.
        balance = self.verified_invoice_balance(context, initial)
        source_amount = self.verify_refund_source(context, initial) if initial["kind"] == "refund" else None
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.row(connection, attempt_id)
            actor = self.authorize(connection, session_id, row, ownership=True)
            self.connection_context(connection, row, require_grant=True)
            if row["state"] != "reserved":
                raise AttemptError("dispatch_already_started", "This payment may already have been sent. Reconcile the original attempt; do not send it again.")
            self.billing_publication_boundary(connection, row)
            if row["kind"] == "charge" and row["amount_cents"] > balance:
                raise AttemptError("balance_exceeded", "The invoice balance changed before collection. Refresh the invoice.")
            if source_amount is not None:
                self.check_refund_limit(connection, row, source_amount)
            now = self.timestamp()
            connection.execute("UPDATE payment_attempts SET state='sending', submitted_at=?, updated_at=? WHERE id=?",
                               (now, now, row["id"]))
            self.event(connection, actor, "begin-dispatch", row["id"])
            return self.public(self.row(connection, row["id"]))

    def cancel(self, session_id, attempt_id):
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.row(connection, attempt_id)
            actor = self.authorize(connection, session_id, row, ownership=True, recovery=True)
            if row["state"] == "cancelled":
                return self.public(row)
            if row["state"] != "reserved":
                raise AttemptError("dispatch_may_have_started", "A sent or uncertain payment cannot be cancelled locally. Reconcile it in QuickBooks.")
            connection.execute("UPDATE payment_attempts SET state='cancelled', updated_at=? WHERE id=?",
                               (self.timestamp(), row["id"]))
            self.event(connection, actor, "cancel-reservation", row["id"])
            return self.public(self.row(connection, row["id"]))

    def get(self, session_id, attempt_id):
        with self.database() as connection:
            row = self.row(connection, attempt_id)
            self.authorize(connection, session_id, row, ownership=True, recovery=True)
            return self.public(row)

    def list_for_invoice(self, session_id, company_id, invoice_id):
        company_id, invoice_id = canonical_uuid(company_id), canonical_uuid(invoice_id)
        with self.database() as connection:
            actor = self.actor(connection, session_id)
            company = connection.execute("SELECT company_id FROM company_identity WHERE singleton=1").fetchone()
            if company is None or company["company_id"] != company_id:
                raise AttemptError("company_changed", "The business workspace changed.", 403)
            rows = connection.execute(
                "SELECT * FROM payment_attempts WHERE company_id=? AND invoice_id=? ORDER BY created_at DESC LIMIT 100",
                (company_id, invoice_id),
            ).fetchall()
            result = []
            for row in rows:
                try:
                    self.authorize(connection, session_id, row, ownership=True, recovery=True)
                except AttemptError:
                    continue
                result.append(self.public(row))
            return result

    def verify_provider(self, payload, row):
        if not isinstance(payload, dict) or payload.get("id") is None:
            raise AttemptError("provider_unconfirmed", "QuickBooks did not return a verifiable transaction.")
        provider_id = reference(payload["id"])
        context = payload.get("context")
        if not isinstance(context, dict) or context.get("clientTransID") != row["client_transaction_id"]:
            raise AttemptError("provider_mismatch", "The provider transaction belongs to a different collection attempt.")
        if money_cents(payload.get("amount")) != row["amount_cents"]:
            raise AttemptError("provider_mismatch", "The provider amount differs from this collection attempt.")
        currency = payload.get("currency", "USD" if row["rail"] == "ach" else None)
        if currency != "USD":
            raise AttemptError("provider_mismatch", "The provider transaction currency could not be verified.")
        status = payload.get("status")
        if not isinstance(status, str):
            raise AttemptError("provider_unconfirmed", "The provider transaction status is missing.")
        status = status.upper()
        accepted = {"CAPTURED"} if row["kind"] == "charge" and row["rail"] == "card" else (
            {"PENDING", "SUCCEEDED", "SETTLED"} if row["kind"] == "charge" else {"REFUNDED", "PENDING"}
        )
        if status not in accepted:
            raise AttemptError("provider_unconfirmed", "The provider transaction requires accounting review.")
        return provider_id, status

    def confirm(self, session_id, attempt_id, provider_id):
        provider_id = reference(provider_id)
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = dict(self.row(connection, attempt_id))
            actor = self.authorize(connection, session_id, row, ownership=True, recovery=True)
            context = self.connection_context(connection, row, require_grant=True)
            if row["state"] not in ("sending", "unknown", "confirmed", "completed"):
                raise AttemptError("not_dispatched", "This attempt has not been dispatched.")
            if row["provider_id"] is not None and row["provider_id"] != provider_id:
                raise AttemptError("provider_conflict", "This attempt already has a different provider transaction.")
            if row["provider_id"] is None and row["candidate_provider_id"] != provider_id:
                if row["candidate_provider_id"] is not None and actor["role"] == "Field Technician":
                    raise AttemptError("candidate_review", "An office user must review a changed provider reference.", 403)
                # A hint is not confirmation. Persist it before the read so a
                # timeout/restart can resume verification without losing the ID.
                connection.execute("UPDATE payment_attempts SET candidate_provider_id=?, updated_at=? WHERE id=?",
                                   (provider_id, self.timestamp(), row["id"]))
                self.event(connection, actor, "record-provider-reference", row["id"])
        payload = self.read_transaction(context, row["kind"], row["rail"], row["source_provider_id"], provider_id)
        confirmed_id, provider_status = self.verify_provider(payload, row)
        if confirmed_id != provider_id:
            raise AttemptError("provider_mismatch", "The returned provider identifier did not match the requested transaction.")
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            current = self.row(connection, attempt_id)
            actor = self.authorize(connection, session_id, current, ownership=True, recovery=True)
            self.connection_context(connection, current, require_grant=True)
            if current["provider_id"] is not None and current["provider_id"] != confirmed_id:
                raise AttemptError("provider_conflict", "This attempt already has a different provider transaction.")
            if current["state"] in ("confirmed", "completed"):
                return self.public(current)
            if current["state"] not in ("sending", "unknown"):
                raise AttemptError("state_changed", "The payment state changed. Review it before proceeding.")
            now = self.timestamp()
            try:
                connection.execute(
                    """UPDATE payment_attempts SET state='confirmed', provider_id=?, provider_status=?,
                       confirmed_at=?, updated_at=? WHERE id=?""",
                    (confirmed_id, provider_status, now, now, current["id"]),
                )
            except sqlite3.IntegrityError:
                raise AttemptError("provider_already_linked", "That provider transaction is already linked to another attempt.") from None
            if current["kind"] == "charge":
                connection.execute(
                    """UPDATE payment_invoice_limits SET balance_ceiling_cents=MAX(0,balance_ceiling_cents-?), updated_at=?
                       WHERE company_id=? AND realm_id=? AND environment=? AND invoice_qbo_id=?""",
                    (current["amount_cents"], now, current["company_id"], current["realm_id"],
                     current["environment"], current["invoice_qbo_id"]),
                )
            self.event(connection, actor, "confirm-provider", current["id"])
            return self.public(self.row(connection, current["id"]))

    def unknown(self, session_id, attempt_id):
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.row(connection, attempt_id)
            actor = self.authorize(connection, session_id, row, ownership=True, recovery=True)
            if row["state"] == "sending":
                connection.execute("UPDATE payment_attempts SET state='unknown', updated_at=? WHERE id=?",
                                   (self.timestamp(), row["id"]))
                self.event(connection, actor, "unconfirmed", row["id"])
            return self.public(self.row(connection, row["id"]))

    @staticmethod
    def verify_accounting(payload, row):
        if not isinstance(payload, dict) or reference_value(payload, "CustomerRef") != row["customer_qbo_id"]:
            raise AttemptError("accounting_mismatch", "The accounting customer could not be verified.")
        if money_cents(payload.get("TotalAmt")) != row["amount_cents"]:
            raise AttemptError("accounting_mismatch", "The accounting amount differs from the collection.")
        notes = payload.get("PrivateNote", "")
        if not isinstance(notes, str):
            raise AttemptError("accounting_mismatch", "The accounting recovery identity is missing.")
        marker = ("GunnAire payment ID: " + row["id"]) if row["kind"] == "charge" else (
            "Client transaction ID: " + row["client_transaction_id"]
        )
        if marker not in notes.splitlines():
            raise AttemptError("accounting_mismatch", "The accounting record belongs to a different collection.")
        if row["kind"] == "charge":
            lines = payload.get("Line")
            if not isinstance(lines, list) or not lines:
                raise AttemptError("accounting_mismatch", "The accounting payment has no invoice allocation.")
            total = 0
            for line in lines:
                links = line.get("LinkedTxn") if isinstance(line, dict) else None
                if not isinstance(links, list) or len(links) != 1 or not isinstance(links[0], dict):
                    raise AttemptError("accounting_mismatch", "The accounting invoice allocation is ambiguous.")
                if links[0].get("TxnId") != row["invoice_qbo_id"] or links[0].get("TxnType") != "Invoice":
                    raise AttemptError("accounting_mismatch", "The accounting invoice allocation is ambiguous.")
                total += money_cents(line.get("Amount"))
            if total != row["amount_cents"]:
                raise AttemptError("accounting_mismatch", "The accounting allocation amount differs from the collection.")

    def complete(self, session_id, attempt_id, accounting_id):
        accounting_id = reference(accounting_id)
        with self.database() as connection:
            row = dict(self.row(connection, attempt_id))
            self.authorize(connection, session_id, row, ownership=True, recovery=True)
            context = self.connection_context(connection, row, require_grant=True)
            if row["state"] not in ("confirmed", "completed"):
                raise AttemptError("provider_required", "Confirm the provider transaction before completing accounting.")
            if row["accounting_id"] is not None and row["accounting_id"] != accounting_id:
                raise AttemptError("accounting_conflict", "The attempt already has another accounting record.")
        payload = self.read_accounting(context, row["kind"], accounting_id)
        if not isinstance(payload, dict) or payload.get("Id") != accounting_id:
            raise AttemptError("accounting_mismatch", "The returned accounting identifier did not match.")
        self.verify_accounting(payload, row)
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            current = self.row(connection, attempt_id)
            actor = self.authorize(connection, session_id, current, ownership=True, recovery=True)
            self.connection_context(connection, current, require_grant=True)
            if current["state"] == "completed":
                if current["accounting_id"] != accounting_id:
                    raise AttemptError("accounting_conflict", "The attempt already has another accounting record.")
                return self.public(current)
            if current["state"] != "confirmed":
                raise AttemptError("state_changed", "The payment state changed. Review it before proceeding.")
            now = self.timestamp()
            connection.execute(
                "UPDATE payment_attempts SET state='completed', accounting_id=?, completed_at=?, updated_at=? WHERE id=?",
                (accounting_id, now, now, current["id"]),
            )
            self.event(connection, actor, "complete-accounting", current["id"])
            return self.public(self.row(connection, current["id"]))
