"""Shared invoice/estimate publication engine.

Provider writes require a current office role, an exact reviewed draft grant,
or a server-recorded job assignment with current pricebook evidence. No device-
supplied job assignment establishes authority. Native cutover remains separate.
Unknown outcomes never authorize another send. No payment, email, void or delete.
"""
from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import uuid
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

try:
    from Backend import billing_assignments
    from Backend.catalog_publications import canonical, failure, scope
    from Backend.payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference
except ModuleNotFoundError:
    import billing_assignments
    from catalog_publications import canonical, failure, scope
    from payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference


SCHEMA = """
CREATE TABLE IF NOT EXISTS billing_publications (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, realm_id TEXT NOT NULL,
 environment TEXT NOT NULL, document_type TEXT NOT NULL, local_document_id TEXT NOT NULL,
 local_customer_id TEXT NOT NULL, operation TEXT NOT NULL,
 payload_hash TEXT NOT NULL, payload_ciphertext TEXT NOT NULL, grant_fingerprint TEXT NOT NULL,
 request_id TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('reserved','sending','unknown','confirmed','cancelled')),
 provider_id TEXT, actor_email TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS billing_open_document ON billing_publications
 (company_id,realm_id,environment,document_type,local_document_id)
 WHERE state IN ('reserved','sending','unknown');
CREATE TABLE IF NOT EXISTS billing_entity_mappings (
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 document_type TEXT NOT NULL, local_document_id TEXT NOT NULL, local_customer_id TEXT NOT NULL,
 provider_id TEXT NOT NULL,
 PRIMARY KEY(company_id,realm_id,environment,document_type,local_document_id),
 UNIQUE(company_id,realm_id,environment,document_type,provider_id)
);
CREATE TABLE IF NOT EXISTS billing_draft_grants (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 document_type TEXT NOT NULL, local_document_id TEXT NOT NULL, payload_hash TEXT NOT NULL,
 grant_fingerprint TEXT NOT NULL, technician_email TEXT NOT NULL, approved_by TEXT NOT NULL,
 created_at TEXT NOT NULL, expires_at TEXT NOT NULL, revoked_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS billing_active_draft_grant ON billing_draft_grants
 (company_id,realm_id,environment,document_type,local_document_id,payload_hash,technician_email)
 WHERE revoked_at IS NULL;
"""


def initialize_schema(connection):
    billing_assignments.initialize_schema(connection)
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)


def number(value, *, places=2, maximum="99999999999", positive=False):
    if type(value) not in (int, float) or len(str(value)) > 64:
        raise failure("invalid_amount", "Use finite billing amounts with the supported precision.", 400)
    try:
        result = Decimal(str(value))
        if (not result.is_finite() or result < 0 or result > Decimal(maximum)
                or (positive and result == 0) or result != result.quantize(Decimal(10) ** -places)):
            raise InvalidOperation()
        return result
    except InvalidOperation:
        raise failure("invalid_amount", "Review billing amounts, quantities and precision.", 400) from None


def bounded_text(value, maximum, *, multiline=False):
    if (not isinstance(value, str) or len(value) > maximum
            or any((ord(c) < 32 and not (multiline and c in "\n\t")) or ord(c) == 127 for c in value)):
        raise failure("invalid_document", "Review the document's text fields and lengths.", 400)
    return value


def ref(value):
    if not isinstance(value, dict) or set(value) - {"value", "name"} or "value" not in value:
        raise failure("invalid_document", "Select an exact accounting reference.", 400)
    if "name" in value:
        bounded_text(value["name"], 500)
    return {"value": reference(value["value"])}


def line_values(values):
    if not isinstance(values, list) or not 1 <= len(values) <= 750:
        raise failure("invalid_lines", "Use between one and 750 billing lines.", 400)
    result, subtotal, discounted = [], Decimal(0), False
    for index, line in enumerate(values):
        if not isinstance(line, dict) or set(line) - {"Amount", "DetailType", "Description", "SalesItemLineDetail", "DiscountLineDetail"}:
            raise failure("invalid_lines", "Use supported sold items and one final document discount.", 400)
        amount = number(line.get("Amount"))
        kind = line.get("DetailType")
        value = {"Amount": float(amount), "DetailType": kind}
        if "Description" in line:
            description = bounded_text(line["Description"], 4000, multiline=True)
            if description:
                value["Description"] = description
        if kind == "SalesItemLineDetail":
            detail = line.get(kind)
            if (discounted or "DiscountLineDetail" in line or not isinstance(detail, dict)
                    or set(detail) - {"ItemRef", "Qty", "UnitPrice", "TaxCodeRef"}
                    or not {"ItemRef", "Qty", "UnitPrice", "TaxCodeRef"} <= set(detail)):
                raise failure("invalid_lines", "Each sold line needs an item, quantity, price and tax choice.", 400)
            qty = number(detail["Qty"], places=5, maximum="999999", positive=True)
            price = number(detail["UnitPrice"], places=5)
            if (qty * price).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP) != amount:
                raise failure("invalid_lines", "The sold line amount does not match its quantity and price.", 400)
            tax = ref(detail["TaxCodeRef"])
            if tax["value"] not in ("TAX", "NON"):
                raise failure("invalid_lines", "Choose the supported US taxable or nontaxable line setting.", 400)
            value[kind] = {"ItemRef": ref(detail["ItemRef"]), "Qty": float(qty), "UnitPrice": float(price), "TaxCodeRef": tax}
            subtotal += amount
        elif kind == "DiscountLineDetail":
            detail = line.get(kind)
            if (index == 0 or index != len(values) - 1 or discounted or "SalesItemLineDetail" in line
                    or not isinstance(detail, dict) or set(detail) - {"PercentBased", "DiscountPercent"}
                    or type(detail.get("PercentBased")) is not bool or amount > subtotal):
                raise failure("invalid_lines", "Review the final document discount.", 400)
            value[kind] = {"PercentBased": detail["PercentBased"]}
            if detail["PercentBased"]:
                percent = number(detail.get("DiscountPercent"), places=5, maximum="100")
                if (subtotal * percent / 100).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP) != amount:
                    raise failure("invalid_lines", "The percentage discount does not match its amount.", 400)
                value[kind]["DiscountPercent"] = float(percent)
            elif "DiscountPercent" in detail:
                raise failure("invalid_lines", "A fixed discount cannot also specify a percentage.", 400)
            discounted = True
        else:
            raise failure("invalid_lines", "Unsupported billing line type.", 400)
        result.append(value)
    number(float(subtotal))
    return result


def document_values(value, kind, operation):
    allowed = {"CustomerRef", "Line", "PrivateNote", "BillEmail", "ShipAddr", "ShipFromAddr", "DueDate", "TxnDate",
               "GlobalTaxCalculation", "ApplyTaxAfterDiscount", "CurrencyRef"}
    if operation == "update":
        allowed |= {"Id", "SyncToken", "sparse"}
    required = {"CustomerRef", "Line"} | ({"TxnDate"} if operation == "create" else set())
    if not isinstance(value, dict) or set(value) - allowed or not required <= set(value):
        raise failure("invalid_document", "Use only the supported accounting document fields.", 400)
    result = {"CustomerRef": ref(value["CustomerRef"]), "Line": line_values(value["Line"])}
    if "PrivateNote" in value:
        result["PrivateNote"] = bounded_text(value["PrivateNote"], 3800, multiline=True)
        if any(line.strip().casefold().startswith(("gunnaire invoice id:", "gunnaire estimate id:", "gunnaire publication:"))
               for line in result["PrivateNote"].splitlines()):
            raise failure("invalid_document", "Document lineage is assigned by the server.", 400)
    for key in ("DueDate", "TxnDate"):
        if key in value:
            if not isinstance(value[key], str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value[key]):
                raise failure("invalid_document", "Use a complete billing date.", 400)
            try:
                date.fromisoformat(value[key])
            except ValueError:
                raise failure("invalid_document", "Use a valid billing date.", 400) from None
            result[key] = value[key]
    if kind == "Estimate" and "DueDate" in result:
        raise failure("invalid_document", "Due dates apply to invoices.", 400)
    if "BillEmail" in value:
        email = value["BillEmail"]
        if not isinstance(email, dict) or set(email) != {"Address"} or not isinstance(email["Address"], str) or not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email["Address"]):
            raise failure("invalid_document", "Use a valid billing email address.", 400)
        result["BillEmail"] = {"Address": bounded_text(email["Address"], 100)}
    for key in ("ShipAddr", "ShipFromAddr"):
        if key not in value:
            continue
        address = value[key]
        limits = {"Line1": 500, "Line2": 500, "Line3": 500, "Line4": 500, "Line5": 500,
                  "City": 255, "CountrySubDivisionCode": 255, "PostalCode": 30, "Country": 255}
        if not isinstance(address, dict) or not address or set(address) - set(limits):
            raise failure("invalid_document", "Use a supported service or origin address.", 400)
        result[key] = {field: bounded_text(content, limits[field]) for field, content in address.items()}
    if value.get("GlobalTaxCalculation", "TaxExcluded") != "TaxExcluded":
        raise failure("invalid_document", "Use tax-exclusive sold prices for this US billing workflow.", 400)
    if "ApplyTaxAfterDiscount" in value:
        if type(value["ApplyTaxAfterDiscount"]) is not bool:
            raise failure("invalid_document", "Use an explicit tax-after-discount choice.", 400)
        result["ApplyTaxAfterDiscount"] = value["ApplyTaxAfterDiscount"]
    if any(line["DetailType"] == "DiscountLineDetail" for line in result["Line"]) and result.get("ApplyTaxAfterDiscount") is not True:
        raise failure("invalid_document", "Confirm tax after the document discount.", 400)
    if "CurrencyRef" in value:
        if ref(value["CurrencyRef"])["value"] != "USD":
            raise failure("invalid_document", "This billing workflow requires US dollars.", 400)
        result["CurrencyRef"] = {"value": "USD"}
    if operation == "update":
        if value.get("sparse") is not True:
            raise failure("invalid_document", "Use a reviewed sparse invoice update.", 400)
        result.update(Id=reference(value.get("Id")), SyncToken=reference(value.get("SyncToken")), sparse=True)
    return result


def validated_request(payload):
    required = {"companyID", "realmID", "environment", "documentType", "localDocumentID", "localCustomerID", "operation", "document", "connectionRevision"}
    shapes = (required, required | {"serviceCallID"}, required | {"serviceCallID", "assignmentRevision"})
    if not isinstance(payload, dict) or set(payload) not in (*shapes, *(shape | {"draftRevision"} for shape in shapes)):
        raise failure("invalid_request", "Use the supported billing publication fields only.", 400)
    epoch = payload["connectionRevision"]
    if not isinstance(epoch, str) or not re.fullmatch(r"[0-9a-f]{64}", epoch):
        raise failure("invalid_request", "Refresh the original billing connection before preparing a proposal.", 400)
    kind, operation = payload["documentType"], payload["operation"]
    if (kind not in ("Invoice", "Estimate") or operation not in ("create", "update")
            or (kind == "Estimate" and operation != "create") or payload["environment"] not in ("sandbox", "production")):
        raise failure("invalid_request", "Choose a supported billing operation and environment.", 400)
    job = {"connection_revision": epoch}
    if "draftRevision" in payload:
        revision = payload["draftRevision"]
        if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{64}", revision):
            raise failure("invalid_request", "Retain the original native draft revision.", 400)
        job["draft_revision"] = revision
    if "serviceCallID" in payload:
        job["service_call_id"] = canonical_uuid(payload["serviceCallID"])
        if "assignmentRevision" in payload:
            revision = payload["assignmentRevision"]
            if type(revision) is not int or not 1 <= revision <= 2147483647:
                raise failure("invalid_request", "Use the original server-approved assignment revision.", 400)
            job["assignment_revision"] = revision
    return {"company_id": canonical_uuid(payload["companyID"]), "realm_id": reference(payload["realmID"]),
            "environment": payload["environment"], "document_type": kind, "operation": operation,
            "local_document_id": canonical_uuid(payload["localDocumentID"]), "local_customer_id": canonical_uuid(payload["localCustomerID"]),
            "document": document_values(payload["document"], kind, operation), **job}


def digest(intent):
    return hashlib.sha256(canonical(intent).encode()).hexdigest()


def office_role(role, kind):
    return role == "Admin" or (role == "Accounting" and kind == "Invoice") or (role == "Dispatcher" and kind == "Estimate")


def marker(row):
    return "GunnAire " + row["document_type"] + " ID: " + row["local_document_id"].upper()


def publication_marker(row):
    return "GunnAire Publication: " + row["id"]


def document_scope(row):
    return (*scope(row), row["document_type"], row["local_document_id"])


class BillingPublisher:
    def __init__(self, database, provider_factory, encrypt, decrypt, audit, now=None):
        self.database, self.provider_factory, self.encrypt, self.decrypt, self.audit = database, provider_factory, encrypt, decrypt, audit
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.assignments = billing_assignments.JobBillingAssignments(database, self.actor, encrypt, decrypt, audit, self.now)

    def actor(self, connection, session_id):
        actor = connection.execute("SELECT s.*,u.role,u.is_active FROM auth_sessions s JOIN users u ON u.email=s.email WHERE s.id=?", (session_id,)).fetchone()
        try:
            issued = datetime.fromisoformat(actor["created_at"].replace("Z", "+00:00"))
            expires = datetime.fromisoformat(actor["expires_at"].replace("Z", "+00:00"))
            valid = actor["revoked_at"] is None and actor["is_active"] and issued.tzinfo and expires.tzinfo and issued <= self.now() < expires
        except (TypeError, ValueError):
            valid = False
        if not valid:
            raise failure("access_denied", "Sign in with current business access.", 403)
        return actor

    def authorize(self, connection, session_id, intent, *, require_grant=True, office_only=False):
        actor = self.actor(connection, session_id)
        company = connection.execute("SELECT company_id FROM company_identity WHERE singleton=1").fetchone()
        if company is None or company[0] != intent["company_id"]:
            raise failure("company_changed", "Reopen the original business workspace.", 403)
        grant = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
        if grant is None or grant["realm_id"] != intent["realm_id"] or grant["environment"] != intent["environment"]:
            raise failure("provider_changed", "Reconnect the original QuickBooks company.")
        fingerprint = grant_fingerprint(grant)
        if "connection_revision" in intent.keys() and intent["connection_revision"] != billing_assignments.connection_revision(fingerprint):
            raise failure("grant_changed", "Keep the original proposal. Review billing after reconnecting QuickBooks.")
        if require_grant and fingerprint != intent["grant_fingerprint"]:
            raise failure("grant_changed", "Review the original attempt after reconnecting QuickBooks.")
        allowed = office_role(actor["role"], intent["document_type"])
        authority = "office" if allowed else None
        if not allowed and not office_only and actor["role"] == "Field Technician":
            hash_value = intent["payload_hash"] if "payload_hash" in intent.keys() else digest(intent)
            grants = connection.execute("""SELECT g.*,u.role,u.is_active FROM billing_draft_grants g JOIN users u ON u.email=g.approved_by
                WHERE g.company_id=? AND g.realm_id=? AND g.environment=? AND g.document_type=? AND g.local_document_id=?
                AND g.payload_hash=? AND g.technician_email=? AND g.grant_fingerprint=? AND g.revoked_at IS NULL""",
                (*document_scope(intent), hash_value, actor["email"], fingerprint)).fetchall()
            for approved in grants:
                try:
                    start, end = datetime.fromisoformat(approved["created_at"]), datetime.fromisoformat(approved["expires_at"])
                    allowed = (approved["is_active"] and office_role(approved["role"], intent["document_type"])
                               and start.tzinfo is not None and end.tzinfo is not None and start <= self.now() < end)
                except (TypeError, ValueError):
                    allowed = False
                if allowed:
                    authority = "reviewed"
                    break
            if not allowed:
                proposal = self.intent(intent) if "payload_ciphertext" in intent.keys() else intent
                allowed = self.assignments.authorize_field(connection, actor, proposal, fingerprint)
                if allowed:
                    authority = "assigned"
        if not allowed:
            raise failure("review_required", "Keep the saved draft. Confirm current job billing access or ask the office to review it.", 403)
        return actor, {**dict(grant), "grant_fingerprint": fingerprint, "billing_authority": authority}

    def approve_draft(self, session_id, payload, technician_email, *, original_attempt=None):
        intent = validated_request(payload)
        if not isinstance(technician_email, str) or technician_email != technician_email.strip().lower():
            raise failure("invalid_request", "Choose an active field technician.", 400)
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, context = self.authorize(connection, session_id, intent, require_grant=False, office_only=True)
            if original_attempt is not None:
                original = self.record(connection, original_attempt)
                self.authorize(connection, session_id, original, office_only=True)
                if original["state"] != "reserved" or original["payload_hash"] != digest(intent) or original["actor_email"] != technician_email:
                    raise failure("proposal_changed", "Only the exact original never-sent proposal can be approved.")
            user = connection.execute("SELECT * FROM users WHERE email=?", (technician_email,)).fetchone()
            if user is None or not user["is_active"] or user["role"] != "Field Technician":
                raise failure("invalid_request", "Choose an active field technician.", 400)
            identifier, now = str(uuid.uuid4()), self.now()
            # A reviewed revision supersedes every older revision for this
            # document, including another crew member's old permission. The
            # same revision may still be approved for multiple technicians.
            connection.execute("""UPDATE billing_draft_grants SET revoked_at=? WHERE company_id=? AND realm_id=? AND environment=?
                AND document_type=? AND local_document_id=? AND (payload_hash!=? OR technician_email=?) AND revoked_at IS NULL""",
                (now.isoformat(), *document_scope(intent), digest(intent), technician_email))
            connection.execute("INSERT INTO billing_draft_grants VALUES (?,?,?,?,?,?,?,?,?,?,?,?,NULL)",
                (identifier, *document_scope(intent), digest(intent), context["grant_fingerprint"], technician_email,
                 actor["email"], now.isoformat(), (now + timedelta(days=7)).isoformat()))
            self.audit(actor["email"], "approve", "billing-draft", identifier, connection=connection)
            return identifier

    def revoke_draft(self, session_id, identifier):
        identifier = canonical_uuid(identifier)
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("SELECT * FROM billing_draft_grants WHERE id=?", (canonical_uuid(identifier),)).fetchone()
            if row is None:
                raise failure("not_found", "Draft approval not found.", 404)
            actor, _ = self.authorize(connection, session_id, row, require_grant=False, office_only=True)
            if row["revoked_at"] is None:
                connection.execute("UPDATE billing_draft_grants SET revoked_at=? WHERE id=?", (self.now().isoformat(), identifier))
                self.audit(actor["email"], "revoke", "billing-draft", identifier, connection=connection)

    def record(self, connection, identifier):
        row = connection.execute("SELECT * FROM billing_publications WHERE id=?", (canonical_uuid(identifier),)).fetchone()
        if row is None:
            raise failure("not_found", "Billing publication not found.", 404)
        return row

    def intent(self, row):
        try:
            value = json.loads(self.decrypt(row["payload_ciphertext"]) or "")
            if digest(value) != row["payload_hash"]:
                raise ValueError()
            for key in ("company_id", "realm_id", "environment", "document_type", "local_document_id", "local_customer_id", "operation"):
                if value[key] != row[key]:
                    raise ValueError()
            document_values(value["document"], row["document_type"], row["operation"])
            return value
        except (ValueError, TypeError, KeyError, AttemptError):
            raise failure("storage_unavailable", "The original saved billing proposal could not be verified.", 503) from None

    def mappings(self, connection, intent):
        document = intent["document"]
        mapping = connection.execute("SELECT provider_id FROM customer_entity_mappings WHERE company_id=? AND realm_id=? AND environment=? AND local_customer_id=?",
            (*scope(intent), intent["local_customer_id"])).fetchone()
        if mapping is None or mapping[0] != document["CustomerRef"]["value"]:
            raise failure("customer_review", "Establish this customer's verified shared QuickBooks link first.")
        for line in document["Line"]:
            if line["DetailType"] != "SalesItemLineDetail":
                continue
            item_id = line["SalesItemLineDetail"]["ItemRef"]["value"]
            if connection.execute("SELECT 1 FROM catalog_entity_mappings WHERE company_id=? AND realm_id=? AND environment=? AND provider_id=?",
                                  (*scope(intent), item_id)).fetchone() is None:
                raise failure("item_review", "Publish or review the sold item's shared pricebook link first.")

    @staticmethod
    def payment_boundary(connection, intent):
        if intent["document_type"] != "Invoice":
            return
        identifier = intent["document"].get("Id", "")
        payment = connection.execute("""SELECT 1 FROM payment_attempts WHERE company_id=? AND realm_id=? AND environment=?
            AND (invoice_id=? OR invoice_qbo_id=?) AND state NOT IN ('cancelled','declined') LIMIT 1""",
            (*scope(intent), intent["local_document_id"], identifier)).fetchone()
        if payment:
            raise failure("payment_review", "Review this invoice's payment activity before changing its accounting record.")

    @staticmethod
    def document_mapping(connection, intent):
        linked = connection.execute("SELECT * FROM billing_entity_mappings WHERE company_id=? AND realm_id=? AND environment=? AND document_type=? AND local_document_id=?", document_scope(intent)).fetchone()
        if intent["operation"] == "create" and linked is not None:
            raise failure("identity_conflict", "Update or recover the original accounting document; do not create another.")
        if intent["operation"] == "update" and (linked is None or linked["provider_id"] != intent["document"]["Id"] or linked["local_customer_id"] != intent["local_customer_id"]):
            raise failure("identity_conflict", "Review the original server-owned invoice mapping before updating.")

    def reserve(self, session_id, payload):
        intent = validated_request(payload)
        hash_value, ciphertext = digest(intent), self.encrypt(canonical(intent))
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, context = self.authorize(connection, session_id, intent, require_grant=False)
            self.mappings(connection, intent)
            rows = connection.execute("""SELECT * FROM billing_publications WHERE company_id=? AND realm_id=? AND environment=?
                AND document_type=? AND local_document_id=? AND state!='cancelled' ORDER BY created_at DESC,id DESC""", document_scope(intent)).fetchall()
            for row in rows:
                if row["state"] in ("reserved", "sending", "unknown") or row["payload_hash"] == hash_value or (intent["operation"] == "create" and row["operation"] == "create"):
                    self.authorize(connection, session_id, row)
                    if row["payload_hash"] != hash_value:
                        raise failure("publication_pending", "Review the original document before publishing a changed proposal.")
                    return dict(row)
            self.document_mapping(connection, intent)
            self.payment_boundary(connection, intent)
            self.assignments.bind_document(connection, intent)
            identifier, now = str(uuid.uuid4()), self.now().isoformat()
            request_id = "ga-" + (intent["document_type"].lower() if intent["operation"] == "create" else "update") + "-" + (intent["local_document_id"] if intent["operation"] == "create" else identifier)
            connection.execute("INSERT INTO billing_publications VALUES (?,?,?,?,?,?,?,?,?,?,?,?, 'reserved',NULL,?,?,?)",
                (identifier, *document_scope(intent), intent["local_customer_id"], intent["operation"], hash_value, ciphertext,
                 context["grant_fingerprint"], request_id, actor["email"], now, now))
            self.audit(actor["email"], "reserve", "billing-publication", identifier, connection=connection)
            return dict(self.record(connection, identifier))

    def check(self, session_id, identifier):
        with self.database() as connection:
            row = self.record(connection, identifier)
            _, context = self.authorize(connection, session_id, row)
            if row["state"] == "cancelled":
                raise failure("cancelled", "This unsent proposal was cancelled.")
            self.intent(row)
            return dict(row), context

    def claim(self, session_id, identifier, *, catalog_evidence=None, checked_at=None):
        identifier = canonical_uuid(identifier)
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor, context = self.authorize(connection, session_id, row)
            intent = self.intent(row)
            if context["billing_authority"] == "assigned":
                if checked_at is None or not timedelta(0) <= self.now() - checked_at <= timedelta(seconds=30):
                    raise failure("price_review", "Refresh the original pricebook evidence before publishing this draft.")
                verify_field_prices(intent["document"], catalog_evidence)
            self.mappings(connection, intent)
            if row["state"] != "reserved":
                raise failure("publication_pending", "The original billing request cannot be sent again.")
            self.document_mapping(connection, intent)
            self.payment_boundary(connection, intent)
            connection.execute("UPDATE billing_publications SET state='sending',updated_at=? WHERE id=?", (self.now().isoformat(), identifier))
            self.audit(actor["email"], "dispatch", "billing-publication", identifier, connection=connection)

    def payload(self, row):
        document = dict(self.intent(row)["document"])
        document["PrivateNote"] = "\n".join(filter(None, [document.get("PrivateNote"), marker(row), publication_marker(row)]))
        if row["operation"] == "create":
            # Posting date was captured explicitly in the immutable proposal;
            # neither UTC rollover nor restart changes the business date.
            document["EmailStatus"] = "NotSet"
            if row["document_type"] == "Invoice":
                # Intuit can auto-email imported invoices with inherited online
                # payment flags. Publishing is not customer-send authorization.
                for flag in ("AllowOnlineACHPayment", "AllowOnlineCreditCardPayment", "AllowOnlineAffirmPayment", "AllowOnlinePayPalPayment"):
                    document[flag] = False
        return document

    def confirm(self, session_id, identifier, remote, *, original_attempt):
        identifier = canonical_uuid(identifier)
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor, _ = self.authorize(connection, session_id, row)
            if row["state"] == "cancelled":
                raise failure("cancelled", "This unsent proposal was cancelled.")
            verify_remote(row, self.payload(row), remote, original_attempt=original_attempt)
            if row["provider_id"] and row["provider_id"] != remote["Id"]:
                raise failure("identity_conflict", "The original accounting identity changed.")
            self.mappings(connection, self.intent(row))
            mappings = connection.execute("""SELECT * FROM billing_entity_mappings WHERE company_id=? AND realm_id=? AND environment=?
                AND document_type=? AND (local_document_id=? OR provider_id=?)""", (*document_scope(row), remote["Id"])).fetchall()
            if any(value["local_document_id"] != row["local_document_id"] or value["provider_id"] != remote["Id"] or value["local_customer_id"] != row["local_customer_id"] for value in mappings):
                raise failure("identity_conflict", "This accounting document already belongs to another saved record.")
            connection.execute("INSERT OR IGNORE INTO billing_entity_mappings VALUES (?,?,?,?,?,?,?)",
                               (*document_scope(row), row["local_customer_id"], remote["Id"]))
            if row["state"] != "confirmed":
                connection.execute("UPDATE billing_publications SET state='confirmed',provider_id=?,updated_at=? WHERE id=?", (remote["Id"], self.now().isoformat(), identifier))
                self.audit(actor["email"], "confirm", "billing-publication", identifier, connection=connection)
            return {"publication": self.public(self.record(connection, identifier)), "document": public_document(remote)}

    def run(self, session_id, identifier, *, allow_send=False):
        identifier = canonical_uuid(identifier)
        row, context = self.check(session_id, identifier)
        provider = self.provider_factory(context, lambda: self.check(session_id, identifier))
        document = self.payload(row)
        if row["provider_id"]:
            return self.confirm(session_id, identifier, provider.read(row["document_type"], row["provider_id"]), original_attempt=False)
        if row["operation"] == "update":
            current = provider.read("Invoice", document["Id"])
            if row["state"] != "reserved":
                return self.confirm(session_id, identifier, current, original_attempt=True)
            verify_unpaid_update(document, current)
        else:
            # Full bounded census catches legacy app-created records. The server
            # publication marker is mandatory after an uncertain dispatch.
            remotes = provider.documents(row["document_type"])
            if not isinstance(remotes, list) or any(not isinstance(value, dict) or not isinstance(value.get("PrivateNote", ""), str) for value in remotes):
                raise failure("provider_unconfirmed", "QuickBooks returned incomplete document evidence.")
            matches = [value for value in remotes if marker(row) in value.get("PrivateNote", "").splitlines()]
            if len(matches) > 1:
                raise failure("identity_conflict", "More than one accounting document has this saved identity.")
            if matches:
                return self.confirm(session_id, identifier, matches[0], original_attempt=row["state"] != "reserved")
        if row["state"] != "reserved" or not allow_send:
            raise failure("provider_unconfirmed", "The original accounting request remains unconfirmed. No new request was sent.")
        checked_at = self.now()
        catalog_evidence = provider.preflight(document)
        self.check(session_id, identifier)
        try:
            remote = provider.write(row["document_type"], document, row["request_id"],
                                    lambda: self.claim(session_id, identifier, catalog_evidence=catalog_evidence, checked_at=checked_at))
            return self.confirm(session_id, identifier, remote, original_attempt=True)
        except Exception:
            # Preserve any consumed permit even if the client loses its role,
            # storage fails or the provider accepts but the response is lost.
            with self.database() as connection:
                connection.execute("UPDATE billing_publications SET state='unknown',updated_at=? WHERE id=? AND state='sending'", (self.now().isoformat(), identifier))
            raise

    def publish(self, session_id, payload):
        return self.run(session_id, self.reserve(session_id, payload)["id"], allow_send=True)

    def cancel(self, session_id, identifier):
        identifier = canonical_uuid(identifier)
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor = self.actor(connection, session_id)
            office = office_role(actor["role"], row["document_type"])
            actor, _ = self.authorize(connection, session_id, row, require_grant=not office, office_only=office)
            if row["state"] != "reserved":
                raise failure("publication_pending", "Only a never-sent billing proposal can be cancelled.")
            connection.execute("UPDATE billing_publications SET state='cancelled',updated_at=? WHERE id=?", (self.now().isoformat(), identifier))
            self.audit(actor["email"], "cancel", "billing-publication", identifier, connection=connection)
            return {"publication": self.public(self.record(connection, identifier))}

    def list_for_document(self, session_id, payload):
        required = {"companyID", "realmID", "environment", "documentType", "localDocumentID"}
        if not isinstance(payload, dict) or set(payload) not in (required, required | {"cursor"}) or payload.get("documentType") not in ("Invoice", "Estimate"):
            raise failure("invalid_query", "Choose one billing document in its original workspace.", 400)
        intent = billing_assignments.request_scope({**payload, "serviceCallID": payload["localDocumentID"]})
        intent.update(document_type=payload["documentType"], local_document_id=intent.pop("service_call_id"))
        with self.database() as connection:
            actor, _ = self.assignments.context(connection, session_id, intent)
            if not office_role(actor["role"], intent["document_type"]) and actor["role"] != "Field Technician":
                raise failure("access_denied", "Current billing access is required.", 403)
            parameters = document_scope(intent)
            predicate = ""
            if "cursor" in payload:
                try:
                    if not isinstance(payload["cursor"], str) or not 1 <= len(payload["cursor"]) <= 2048:
                        raise ValueError()
                    checkpoint = json.loads(self.decrypt(payload["cursor"]) or "")
                    if not isinstance(checkpoint, dict) or set(checkpoint) != {"scope", "id"} or checkpoint["scope"] != list(parameters):
                        raise ValueError()
                    cursor_id = canonical_uuid(checkpoint["id"])
                except (ValueError, TypeError, AttemptError):
                    raise failure("invalid_query", "Refresh the original document's review list.", 400) from None
                cursor = connection.execute("SELECT * FROM billing_publications WHERE id=? AND company_id=? AND realm_id=? AND environment=? AND document_type=? AND local_document_id=?",
                                            (cursor_id, *parameters)).fetchone()
                if cursor is None:
                    raise failure("invalid_query", "Refresh the original document's review list.", 400)
                predicate = " AND (created_at < ? OR (created_at = ? AND id < ?))"
                parameters += (cursor["created_at"], cursor["created_at"], cursor["id"])
            rows = connection.execute("SELECT * FROM billing_publications WHERE company_id=? AND realm_id=? AND environment=? AND document_type=? AND local_document_id=?" + predicate + " ORDER BY created_at DESC,id DESC LIMIT 51", parameters).fetchall()
            visible = []
            for row in rows[:50]:
                if actor["role"] == "Field Technician":
                    try:
                        self.authorize(connection, session_id, row)
                    except AttemptError as error:
                        if error.status == 403 or error.code in ("grant_changed", "provider_changed"):
                            continue
                        raise
                visible.append(self.public(row))
            # Opaque, scope-bound pagination lets a technician pass inaccessible
            # history without exposing another crew's attempt identifiers.
            cursor = self.encrypt(canonical({"scope": list(document_scope(intent)), "id": rows[49]["id"]})) if len(rows) > 50 else None
            return {"publications": visible, "nextCursor": cursor}

    @staticmethod
    def public(row):
        return {key: row[column] for key, column in (("id", "id"), ("companyID", "company_id"), ("realmID", "realm_id"),
            ("environment", "environment"), ("documentType", "document_type"), ("localDocumentID", "local_document_id"),
            ("localCustomerID", "local_customer_id"), ("operation", "operation"),
            ("state", "state"), ("providerID", "provider_id"), ("updatedAt", "updated_at"))}


def verify_field_prices(document, evidence):
    """Authorize sold values, never replace them with today's catalog prices.

Only the fixed-origin server provider supplies this evidence. Price exceptions,
discounts and missing tax evidence use an exact office-reviewed draft grant.
"""
    if not isinstance(evidence, dict):
        raise failure("price_review", "Current pricebook evidence is required for field billing.")
    for line in document["Line"]:
        if line["DetailType"] != "SalesItemLineDetail":
            raise failure("price_review", "Keep the saved discount and ask the office to approve this exact draft.")
        sold = line["SalesItemLineDetail"]
        item = evidence.get(sold["ItemRef"]["value"])
        try:
            valid = (isinstance(item, dict) and item.get("Id") == sold["ItemRef"]["value"]
                     and item.get("Active") is True and item.get("Type") in ("Service", "NonInventory", "Inventory")
                     and type(item.get("Taxable")) is bool and number(item.get("UnitPrice"), places=5) == number(sold["UnitPrice"], places=5)
                     and sold["TaxCodeRef"]["value"] == ("TAX" if item["Taxable"] else "NON"))
        except AttemptError:
            valid = False
        if not valid:
            raise failure("price_review", "Keep the price already sold. Review the current pricebook or request approval for this exact draft.")


def verify_unpaid_update(document, remote):
    if not isinstance(remote, dict) or remote.get("Id") != document["Id"] or not isinstance(remote.get("CustomerRef"), dict) or remote["CustomerRef"].get("value") != document["CustomerRef"]["value"]:
        raise failure("identity_conflict", "Review the original invoice and customer identity.")
    if remote.get("SyncToken") != document["SyncToken"]:
        raise failure("version_changed", "QuickBooks changed this invoice. Review its current version.")
    linked = remote.get("LinkedTxn", [])
    nonfinancial_links = isinstance(linked, list) and all(isinstance(value, dict) and value.get("TxnType") in ("Estimate", "TimeActivity")
        and isinstance(value.get("TxnId"), str) and value["TxnId"] for value in linked)
    if (number(remote.get("Balance")) != number(remote.get("TotalAmt")) or not nonfinancial_links
            or number(remote.get("Deposit", 0)) != 0 or not isinstance(remote.get("PrivateNote", ""), str)
            or remote.get("PrivateNote", "").startswith("Voided")):
        raise failure("payment_review", "Review this invoice's payment and linked-transaction activity before updating.")


def verify_remote(row, expected, remote, *, original_attempt):
    if not isinstance(remote, dict):
        raise failure("provider_unconfirmed", "QuickBooks returned incomplete billing evidence.")
    reference(remote.get("Id")); reference(remote.get("SyncToken"))
    if row["operation"] == "update" and remote["Id"] != expected["Id"]:
        raise failure("identity_conflict", "QuickBooks returned a different invoice.")
    note = remote.get("PrivateNote")
    lines = note.splitlines() if isinstance(note, str) else []
    if lines.count(marker(row)) != 1 or (original_attempt and lines.count(publication_marker(row)) != 1):
        raise failure("provider_unconfirmed", "QuickBooks has not confirmed the original billing operation.")
    reserved = [line for line in lines if line.strip().casefold().startswith(("gunnaire invoice id:", "gunnaire estimate id:"))]
    if reserved != [marker(row)]:
        raise failure("identity_conflict", "QuickBooks returned conflicting document lineage.")
    if not isinstance(remote.get("CustomerRef"), dict) or remote["CustomerRef"].get("value") != expected["CustomerRef"]["value"]:
        raise failure("identity_conflict", "QuickBooks returned a different customer.")
    reported = remote.get("Line")
    if not isinstance(reported, list) or any(not isinstance(value, dict) for value in reported):
        raise failure("provider_unconfirmed", "QuickBooks did not confirm the sold lines.")
    identifiers = [reference(value["Id"]) for value in reported if "Id" in value]
    if len(set(identifiers)) != len(identifiers):
        raise failure("provider_unconfirmed", "QuickBooks repeated a billing-line identity.")
    subtotals = [value for value in reported if value.get("DetailType") == "SubTotalLineDetail"]
    gross = sum((number(value["Amount"]) for value in expected["Line"] if value["DetailType"] == "SalesItemLineDetail"), Decimal(0))
    if len(subtotals) > 1 or (subtotals and number(subtotals[0].get("Amount")) != gross):
        raise failure("provider_unconfirmed", "QuickBooks returned a conflicting billing subtotal.")
    normalized = [{key: value for key, value in line.items() if key in {"Amount", "DetailType", "Description", "SalesItemLineDetail", "DiscountLineDetail"}}
                  for line in reported if line.get("DetailType") != "SubTotalLineDetail"]
    # Provider line details may include calculated/metadata fields; compare only
    # submitted sold values and exact identities, never replace them with cache.
    for line in normalized:
        for detail, allowed in (("SalesItemLineDetail", {"ItemRef", "Qty", "UnitPrice", "TaxCodeRef"}),
                                ("DiscountLineDetail", {"PercentBased", "DiscountPercent"})):
            if isinstance(line.get(detail), dict):
                line[detail] = {key: value for key, value in line[detail].items() if key in allowed}
    if line_values(normalized) != expected["Line"]:
        raise failure("provider_unconfirmed", "QuickBooks returned changed or incomplete sold lines.")
    total = number(remote.get("TotalAmt"))
    tax_detail = remote.get("TxnTaxDetail")
    if not isinstance(tax_detail, dict) or "TotalTax" not in tax_detail:
        raise failure("provider_unconfirmed", "QuickBooks did not confirm the document tax.")
    tax = number(tax_detail["TotalTax"])
    subtotal = sum((number(line["Amount"]) * (-1 if line["DetailType"] == "DiscountLineDetail" else 1) for line in expected["Line"]), Decimal(0))
    if total != subtotal + tax:
        raise failure("provider_unconfirmed", "QuickBooks returned an unreconciled document total.")
    if row["document_type"] == "Invoice" and number(remote.get("Balance")) > total:
        raise failure("provider_unconfirmed", "QuickBooks returned an invalid invoice balance.")
    if not isinstance(remote.get("CurrencyRef", {"value": "USD"}), dict) or remote.get("CurrencyRef", {"value": "USD"}).get("value") != "USD":
        raise failure("provider_unconfirmed", "QuickBooks returned a different document currency.")
    for key in ("DueDate", "TxnDate"):
        if key in expected and remote.get(key) != expected[key]:
            raise failure("provider_unconfirmed", "QuickBooks returned a different billing date.")
    if "BillEmail" in expected and (not isinstance(remote.get("BillEmail"), dict)
            or not isinstance(remote["BillEmail"].get("Address"), str)
            or remote["BillEmail"].get("Address", "").casefold() != expected["BillEmail"]["Address"].casefold()):
        raise failure("provider_unconfirmed", "QuickBooks returned a different billing email address.")


def public_document(remote):
    value = {key: remote[key] for key in ("Id", "SyncToken", "DocNumber", "TotalAmt", "Balance", "TxnDate", "DueDate", "PrivateNote") if key in remote}
    value["CustomerRef"] = ref(remote["CustomerRef"])
    value["TxnTaxDetail"] = {"TotalTax": remote["TxnTaxDetail"]["TotalTax"]}
    value["Line"] = []
    for line in remote["Line"]:
        if line["DetailType"] == "SubTotalLineDetail":
            continue
        filtered = {key: line[key] for key in ("Amount", "DetailType", "Description") if key in line}
        detail = line["DetailType"]
        allowed = {"ItemRef", "Qty", "UnitPrice", "TaxCodeRef"} if detail == "SalesItemLineDetail" else {"PercentBased", "DiscountPercent"}
        filtered[detail] = {key: (ref(content) if key.endswith("Ref") else content) for key, content in line[detail].items() if key in allowed}
        value["Line"].append(filtered)
    if isinstance(remote.get("BillEmail"), dict) and isinstance(remote["BillEmail"].get("Address"), str):
        value["BillEmail"] = {"Address": remote["BillEmail"]["Address"]}
    # Service addresses remain the captured local model values. QBO reformats
    # them; this linking response must not overwrite those values or expose tax IDs.
    return value
