"""Server-owned customer create/link intents; never a general accounting proxy.

Only administrators may mutate the shared customer directory. Field documents
remain saved until an administrator establishes their accounting customer link.
Uncertain writes retain the original intent and can only be recovered by reads.
"""
from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import uuid
from datetime import datetime, timezone

try:
    from Backend.catalog_publications import canonical, failure, scope, connection_pin, validate_connection_pin
    from Backend.payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference
except ModuleNotFoundError:
    from catalog_publications import canonical, failure, scope, connection_pin, validate_connection_pin
    from payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference

SCHEMA = """
CREATE TABLE IF NOT EXISTS customer_publications (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, realm_id TEXT NOT NULL,
 environment TEXT NOT NULL, local_customer_id TEXT NOT NULL,
 payload_hash TEXT NOT NULL, payload_ciphertext TEXT NOT NULL,
 grant_fingerprint TEXT NOT NULL, request_id TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('reserved','sending','unknown','confirmed','cancelled')),
 provider_id TEXT, actor_email TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS customer_open_publication ON customer_publications
 (company_id,realm_id,environment,local_customer_id) WHERE state IN ('reserved','sending','unknown');
CREATE TABLE IF NOT EXISTS customer_entity_mappings (
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 local_customer_id TEXT NOT NULL, provider_id TEXT NOT NULL,
 PRIMARY KEY(company_id,realm_id,environment,local_customer_id),
 UNIQUE(company_id,realm_id,environment,provider_id)
);
CREATE TABLE IF NOT EXISTS customer_publication_keys (
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 identity_hash TEXT NOT NULL, publication_id TEXT NOT NULL,
 PRIMARY KEY(company_id,realm_id,environment,identity_hash)
);
"""


def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)


def text(value):
    return " ".join((value or "").split()).casefold()


def lineage(local_id):
    return "GunnAireCustomerID:" + canonical_uuid(local_id)


def validate_customer(value):
    allowed = {"DisplayName", "PrimaryPhone", "PrimaryEmailAddr", "BillAddr"}
    if not isinstance(value, dict) or set(value) - allowed or "DisplayName" not in value:
        raise failure("invalid_customer", "Use only the supported customer contact fields.", 400)
    name = value["DisplayName"]
    if (not isinstance(name, str) or not name.strip() or name != name.strip() or len(name) > 500
            or any(ord(char) < 32 or ord(char) == 127 or char == ":" for char in name)):
        raise failure("invalid_customer", "Enter a customer name within 500 characters, without colons or control characters.", 400)
    result = {"DisplayName": name}
    for field, child, limit in (("PrimaryPhone", "FreeFormNumber", 30), ("PrimaryEmailAddr", "Address", 100),
                                 ("BillAddr", "Line1", 500)):
        if field not in value:
            continue
        nested = value[field]
        if not isinstance(nested, dict) or set(nested) != {child}:
            raise failure("invalid_customer", "Review the customer's contact information.", 400)
        entry = nested[child]
        if (not isinstance(entry, str) or not entry.strip() or entry != entry.strip() or len(entry) > limit
                or any(ord(char) < 32 or ord(char) == 127 for char in entry)):
            raise failure("invalid_customer", "Review the customer's phone, email and billing-address lengths.", 400)
        if field == "PrimaryEmailAddr" and not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", entry):
            raise failure("invalid_customer", "Enter a valid customer email address.", 400)
        result[field] = {child: entry}
    return result


def validated_request(payload):
    required = {"companyID", "realmID", "environment", "localCustomerID", "customer"}
    if not isinstance(payload, dict) or set(payload) not in (required, required | {"connectionRevision"}):
        raise failure("invalid_request", "Use the supported customer publication fields only.", 400)
    if payload["environment"] not in ("sandbox", "production"):
        raise failure("invalid_request", "Choose a valid QuickBooks environment.", 400)
    return {"company_id": canonical_uuid(payload["companyID"]), "realm_id": reference(payload["realmID"]),
            "environment": payload["environment"], "local_customer_id": canonical_uuid(payload["localCustomerID"]),
            "customer": validate_customer(payload["customer"]), **connection_pin(payload)}


def validated_remote(remote):
    if not isinstance(remote, dict):
        raise failure("provider_unconfirmed", "QuickBooks returned incomplete customer evidence.")
    reference(remote.get("Id"))
    reference(remote.get("SyncToken"))
    if not isinstance(remote.get("DisplayName"), str) or not remote["DisplayName"].strip() or type(remote.get("Active")) is not bool:
        raise failure("provider_unconfirmed", "QuickBooks did not confirm this customer's name and active status.")
    for field, child in (("PrimaryPhone", "FreeFormNumber"), ("PrimaryEmailAddr", "Address"), ("BillAddr", "Line1")):
        if field in remote and (not isinstance(remote[field], dict) or not isinstance(remote[field].get(child, ""), str)):
            raise failure("provider_unconfirmed", "QuickBooks returned incomplete customer contact evidence.")
    if "Notes" in remote and not isinstance(remote["Notes"], str):
        raise failure("provider_unconfirmed", "QuickBooks returned invalid customer lineage.")
    return remote


def contact_values(customer):
    phone = "".join(char for char in customer.get("PrimaryPhone", {}).get("FreeFormNumber", "") if char.isdigit())
    if len(phone) == 11 and phone.startswith("1"):
        phone = phone[1:]
    return (phone, text(customer.get("PrimaryEmailAddr", {}).get("Address")), text(customer.get("BillAddr", {}).get("Line1")))


def public_customer(remote):
    # Provider customers can include tax identifiers, balances and private notes.
    # Native linking requires only contact identity and the explicit active flag.
    result = {key: remote[key] for key in ("Id", "DisplayName", "Active")}
    for field, child in (("PrimaryPhone", "FreeFormNumber"), ("PrimaryEmailAddr", "Address"), ("BillAddr", "Line1")):
        if remote.get(field, {}).get(child):
            result[field] = {child: remote[field][child]}
    return result


def compatible(customer, remote, *, exact=False):
    if text(customer["DisplayName"]) != text(remote["DisplayName"]):
        return False
    return all((not left or left == right) if exact else (not left or not right or left == right)
               for left, right in zip(contact_values(customer), contact_values(remote)))


class CustomerPublisher:
    def __init__(self, database, provider_factory, encrypt, decrypt, audit, now=None):
        self.database, self.provider_factory = database, provider_factory
        self.encrypt, self.decrypt, self.audit = encrypt, decrypt, audit
        self.now = now or (lambda: datetime.now(timezone.utc))

    def authorize(self, connection, session_id, intent, require_grant=True):
        actor = connection.execute("SELECT s.*,u.role,u.is_active FROM auth_sessions s JOIN users u ON u.email=s.email WHERE s.id=?",
                                   (session_id,)).fetchone()
        try:
            issued = datetime.fromisoformat(actor["created_at"].replace("Z", "+00:00"))
            expires = datetime.fromisoformat(actor["expires_at"].replace("Z", "+00:00"))
            valid = (actor["revoked_at"] is None and actor["is_active"] and actor["role"] == "Admin"
                     and issued.tzinfo is not None and expires.tzinfo is not None and issued <= self.now() < expires)
        except (TypeError, ValueError):
            valid = False
        if not valid:
            raise failure("administrator_required", "Ask an administrator to sync this customer before publishing its documents.", 403)
        company = connection.execute("SELECT company_id FROM company_identity WHERE singleton=1").fetchone()
        if company is None or company[0] != intent["company_id"]:
            raise failure("company_changed", "Reopen the original business workspace.", 403)
        grant = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
        if grant is None or grant["realm_id"] != intent["realm_id"] or grant["environment"] != intent["environment"]:
            raise failure("provider_changed", "Reconnect the original QuickBooks company.")
        fingerprint = grant_fingerprint(grant)
        validate_connection_pin(intent, fingerprint)
        if require_grant and fingerprint != intent["grant_fingerprint"]:
            raise failure("grant_changed", "QuickBooks was reconnected. Review the original customer attempt before retrying.")
        return actor, {**dict(grant), "grant_fingerprint": fingerprint}

    def record(self, connection, identifier):
        row = connection.execute("SELECT * FROM customer_publications WHERE id=?", (canonical_uuid(identifier),)).fetchone()
        if row is None:
            raise failure("not_found", "Customer publication not found.", 404)
        return row

    def public(self, row):
        return {key: row[column] for key, column in (("id", "id"), ("companyID", "company_id"), ("realmID", "realm_id"),
            ("environment", "environment"), ("localCustomerID", "local_customer_id"), ("state", "state"),
            ("providerID", "provider_id"), ("updatedAt", "updated_at"))}

    def reserve(self, session_id, payload):
        intent = validated_request(payload)
        # Preserve the existing encrypted-proposal integrity format. The pin
        # is authorization evidence, checked in the reservation transaction
        # and retained by the attempt's original grant_fingerprint.
        digest = hashlib.sha256(canonical({key: value for key, value in intent.items() if key != "connection_revision"}).encode()).hexdigest()
        ciphertext = self.encrypt(canonical(intent["customer"]))
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, grant = self.authorize(connection, session_id, intent, require_grant=False)
            rows = connection.execute("""SELECT * FROM customer_publications WHERE company_id=? AND realm_id=? AND environment=?
                AND local_customer_id=? AND state!='cancelled' ORDER BY created_at DESC""", (*scope(intent), intent["local_customer_id"])).fetchall()
            if rows:
                row = rows[0]
                self.authorize(connection, session_id, row)
                # Even a changed local name cannot create a second provider customer.
                if row["state"] == "confirmed" or row["payload_hash"] == digest:
                    return dict(row)
                raise failure("publication_pending", "The original customer proposal is still pending. Review it before publishing changed contact details.")
            identifier, now = str(uuid.uuid4()), self.now().isoformat()
            connection.execute("INSERT INTO customer_publications VALUES (?,?,?,?,?,?,?,?,?,'reserved',NULL,?,?,?)",
                (identifier, *scope(intent), intent["local_customer_id"], digest, ciphertext, grant["grant_fingerprint"],
                 "ga-customer-" + intent["local_customer_id"], actor["email"], now, now))
            key = hashlib.sha256(text(intent["customer"]["DisplayName"]).encode()).hexdigest()
            try:
                connection.execute("INSERT INTO customer_publication_keys VALUES (?,?,?,?,?)", (*scope(intent), key, identifier))
            except sqlite3.IntegrityError:
                raise failure("customer_busy", "Another proposal for this customer name is pending. Review its original record.") from None
            self.audit(actor["email"], "reserve", "customer-publication", identifier, connection=connection)
            return dict(self.record(connection, identifier))

    def check(self, session_id, identifier):
        with self.database() as connection:
            row = self.record(connection, identifier)
            _, context = self.authorize(connection, session_id, row)
            if row["state"] == "cancelled":
                raise failure("cancelled", "This unsent customer proposal was cancelled.")
            return dict(row), context

    def customer_payload(self, row):
        try:
            customer = validate_customer(json.loads(self.decrypt(row["payload_ciphertext"]) or ""))
            intent = {key: row[key] for key in ("company_id", "realm_id", "environment", "local_customer_id")}
            intent["customer"] = customer
            if hashlib.sha256(canonical(intent).encode()).hexdigest() != row["payload_hash"]:
                raise ValueError()
            return customer
        except (ValueError, TypeError, AttemptError):
            raise failure("storage_unavailable", "The saved customer proposal could not be verified. No new request was sent.", 503) from None

    def mapping(self, connection, row, provider_id):
        rows = connection.execute("""SELECT * FROM customer_entity_mappings WHERE company_id=? AND realm_id=? AND environment=?
            AND (local_customer_id=? OR provider_id=?)""", (*scope(row), row["local_customer_id"], provider_id)).fetchall()
        if any(value["local_customer_id"] != row["local_customer_id"] or value["provider_id"] != provider_id for value in rows):
            raise failure("identity_conflict", "This customer or QuickBooks ID already belongs to a different saved link.")
        connection.execute("INSERT OR IGNORE INTO customer_entity_mappings VALUES (?,?,?,?,?)", (*scope(row), row["local_customer_id"], provider_id))

    def claim(self, session_id, identifier):
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor, _ = self.authorize(connection, session_id, row)
            self.customer_payload(row)
            if row["state"] != "reserved":
                raise failure("publication_pending", "The original customer request is already being reviewed. No second request was sent.")
            existing = connection.execute("SELECT 1 FROM customer_entity_mappings WHERE company_id=? AND realm_id=? AND environment=? AND local_customer_id=?",
                                          (*scope(row), row["local_customer_id"])).fetchone()
            if existing:
                raise failure("identity_conflict", "Recover this customer's original QuickBooks link.")
            connection.execute("UPDATE customer_publications SET state='sending',updated_at=? WHERE id=?", (self.now().isoformat(), identifier))
            self.audit(actor["email"], "dispatch", "customer-publication", identifier, connection=connection)

    def confirm(self, session_id, identifier, remote):
        remote = validated_remote(remote)
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor, _ = self.authorize(connection, session_id, row)
            if row["state"] == "cancelled":
                raise failure("cancelled", "This unsent customer proposal was cancelled.")
            if row["provider_id"] and row["provider_id"] != remote["Id"]:
                raise failure("identity_conflict", "QuickBooks returned a different customer identity.")
            customer = self.customer_payload(row)
            uncertain = row["state"] in ("sending", "unknown")
            if not compatible(customer, remote, exact=uncertain) or (uncertain and remote.get("Notes") != lineage(row["local_customer_id"])):
                raise failure("provider_unconfirmed", "QuickBooks has not confirmed the original customer request.")
            if remote.get("Notes", "").startswith("GunnAireCustomerID:") and remote["Notes"] != lineage(row["local_customer_id"]):
                raise failure("identity_conflict", "This QuickBooks customer belongs to another local record.")
            self.mapping(connection, row, remote["Id"])
            connection.execute("UPDATE customer_publications SET state='confirmed',provider_id=?,updated_at=? WHERE id=?",
                               (remote["Id"], self.now().isoformat(), identifier))
            connection.execute("DELETE FROM customer_publication_keys WHERE publication_id=?", (identifier,))
            self.audit(actor["email"], "confirm", "customer-publication", identifier, connection=connection)
            return {"publication": self.public(self.record(connection, identifier)), "customer": public_customer(remote)}

    def run(self, session_id, identifier, *, allow_send=False):
        row, context = self.check(session_id, identifier)
        customer = self.customer_payload(row)
        provider = self.provider_factory(context, lambda: self.check(session_id, identifier))
        if row["state"] == "confirmed":
            remote = validated_remote(provider.read(row["provider_id"]))
            self.check(session_id, identifier)
            if remote["Id"] != row["provider_id"]:
                raise failure("identity_conflict", "QuickBooks returned a different customer identity.")
            with self.database() as connection:
                connection.execute("BEGIN IMMEDIATE")
                self.authorize(connection, session_id, row)
                self.mapping(connection, row, remote["Id"])
            return {"publication": self.public(row), "customer": public_customer(remote), "created": False}
        candidates = provider.customers()
        self.check(session_id, identifier)
        named, marked, seen = [], [], set()
        for remote in candidates:
            remote = validated_remote(remote)
            if remote["Id"] in seen:
                raise failure("provider_unconfirmed", "QuickBooks repeated a customer in its comparison.")
            seen.add(remote["Id"])
            if text(remote["DisplayName"]) == text(customer["DisplayName"]):
                named.append(remote)
            if remote.get("Notes") == lineage(row["local_customer_id"]):
                marked.append(remote)
        if len(marked) > 1 or len(named) > 1:
            raise failure("identity_conflict", "More than one QuickBooks customer matches this proposal. Review the original records.")
        matches = marked or named
        if matches:
            return {**self.confirm(session_id, identifier, matches[0]), "created": False}
        if not allow_send or row["state"] != "reserved":
            raise failure("outcome_unknown", "Keep the original customer attempt for review. An absent result does not make it safe to resend.")
        claimed = False
        def claim():
            nonlocal claimed
            self.claim(session_id, identifier)
            claimed = True
        try:
            remote = provider.write({**customer, "Notes": lineage(row["local_customer_id"])}, row["request_id"], claim)
            return {**self.confirm(session_id, identifier, remote), "created": True}
        except Exception:
            if claimed:
                with self.database() as connection:
                    connection.execute("UPDATE customer_publications SET state='unknown',updated_at=? WHERE id=? AND state='sending'",
                                       (self.now().isoformat(), identifier))
            raise

    def publish(self, session_id, payload):
        return self.run(session_id, self.reserve(session_id, payload)["id"], allow_send=True)

    def list_for_customer(self, session_id, company_id, customer_id):
        company_id, customer_id = canonical_uuid(company_id), canonical_uuid(customer_id)
        with self.database() as connection:
            grant = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
            if grant is None:
                raise failure("provider_changed", "Reconnect the original QuickBooks company.")
            intent = {"company_id": company_id, "realm_id": grant["realm_id"], "environment": grant["environment"]}
            self.authorize(connection, session_id, intent, require_grant=False)
            return [self.public(row) for row in connection.execute("""SELECT * FROM customer_publications
                WHERE company_id=? AND realm_id=? AND environment=? AND local_customer_id=? ORDER BY created_at DESC LIMIT 100""",
                (*scope(intent), customer_id)).fetchall()]

    def cancel(self, session_id, identifier):
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor, _ = self.authorize(connection, session_id, row)
            if row["state"] != "reserved":
                raise failure("cannot_cancel", "Only a customer proposal that was never sent can be cancelled.")
            connection.execute("UPDATE customer_publications SET state='cancelled',updated_at=? WHERE id=?", (self.now().isoformat(), identifier))
            connection.execute("DELETE FROM customer_publication_keys WHERE publication_id=?", (identifier,))
            self.audit(actor["email"], "cancel", "customer-publication", identifier, connection=connection)
            return {"publication": self.public(self.record(connection, identifier))}
