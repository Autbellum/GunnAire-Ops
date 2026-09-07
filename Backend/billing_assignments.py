"""Office-owned, revisioned job authority for ordinary field billing.

This is not a device assertion that a technician is assigned. Only a current
dispatcher/admin session may record the roster. Offline edits use compare-and-
set and a stable mutation identity; revocations remain as tombstones.
"""
from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone

try:
    from Backend.catalog_publications import canonical, failure, scope
    from Backend.payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference
except ModuleNotFoundError:
    from catalog_publications import canonical, failure, scope
    from payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference


SCHEMA = """
CREATE TABLE IF NOT EXISTS billing_job_assignments (
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 service_call_id TEXT NOT NULL, local_customer_id TEXT NOT NULL,
 revision INTEGER NOT NULL, roster_ciphertext TEXT NOT NULL, roster_hash TEXT NOT NULL,
 enabled INTEGER NOT NULL, grant_fingerprint TEXT NOT NULL, approved_by TEXT NOT NULL, updated_at TEXT NOT NULL,
 PRIMARY KEY(company_id,realm_id,environment,service_call_id)
);
CREATE TABLE IF NOT EXISTS billing_assignment_mutations (
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 operation_id TEXT NOT NULL, service_call_id TEXT NOT NULL, payload_ciphertext TEXT NOT NULL,
 revision INTEGER NOT NULL, grant_fingerprint TEXT NOT NULL,
 PRIMARY KEY(company_id,realm_id,environment,operation_id)
);
CREATE TABLE IF NOT EXISTS billing_job_documents (
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 document_type TEXT NOT NULL, local_document_id TEXT NOT NULL,
 service_call_id TEXT NOT NULL, local_customer_id TEXT NOT NULL,
 PRIMARY KEY(company_id,realm_id,environment,document_type,local_document_id)
);
"""


def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)


def request_scope(payload):
    if not isinstance(payload, dict) or payload.get("environment") not in ("sandbox", "production"):
        raise failure("invalid_request", "Choose the original job and QuickBooks workspace.", 400)
    return {"company_id": canonical_uuid(payload.get("companyID")), "realm_id": reference(payload.get("realmID")),
            "environment": payload["environment"], "service_call_id": canonical_uuid(payload.get("serviceCallID"))}


def roster_values(value):
    if (not isinstance(value, list) or len(value) > 32 or any(not isinstance(email, str) or len(email) > 254
            or email != email.strip().lower() or not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email) for email in value)
            or len(set(value)) != len(value)):
        raise failure("invalid_roster", "Choose distinct active field technicians for this job.", 400)
    return sorted(value)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


class JobBillingAssignments:
    def __init__(self, database, actor, encrypt, decrypt, audit, now=None):
        self.database, self.actor, self.encrypt, self.decrypt, self.audit = database, actor, encrypt, decrypt, audit
        self.now = now or (lambda: datetime.now(timezone.utc))

    def context(self, connection, session_id, intent, *, office=False):
        actor = self.actor(connection, session_id)
        company = connection.execute("SELECT company_id FROM company_identity WHERE singleton=1").fetchone()
        if company is None or company[0] != intent["company_id"]:
            raise failure("company_changed", "Reopen the original business workspace.", 403)
        grant = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
        if grant is None or grant["realm_id"] != intent["realm_id"] or grant["environment"] != intent["environment"]:
            raise failure("provider_changed", "Reconnect the original QuickBooks company.")
        if office and actor["role"] not in ("Admin", "Dispatcher"):
            raise failure("dispatcher_required", "A dispatcher or administrator must approve job billing access.", 403)
        return actor, grant_fingerprint(grant)

    def record(self, connection, intent):
        return connection.execute("SELECT * FROM billing_job_assignments WHERE company_id=? AND realm_id=? AND environment=? AND service_call_id=?",
                                  (*scope(intent), intent["service_call_id"])).fetchone()

    def roster(self, row):
        try:
            envelope = json.loads(self.decrypt(row["roster_ciphertext"]) or "")
            if (not isinstance(envelope, dict) or set(envelope) != {"scope", "customer", "revision", "roster"}
                    or envelope["scope"] != [*scope(row), row["service_call_id"]]
                    or envelope["customer"] != row["local_customer_id"] or envelope["revision"] != row["revision"]
                    or digest(row["roster_ciphertext"]) != row["roster_hash"]):
                raise ValueError()
            return roster_values(envelope["roster"])
        except (ValueError, TypeError, AttemptError):
            raise failure("storage_unavailable", "The original job roster could not be verified.", 503) from None

    def usable(self, connection, row, fingerprint):
        if row is None or not row["enabled"] or row["grant_fingerprint"] != fingerprint:
            return False
        approver = connection.execute("SELECT * FROM users WHERE email=?", (row["approved_by"],)).fetchone()
        return approver is not None and approver["is_active"] and approver["role"] in ("Admin", "Dispatcher")

    def authorize_field(self, connection, actor, intent, fingerprint):
        if actor["role"] != "Field Technician" or not intent.get("service_call_id"):
            return False
        row = self.record(connection, intent)
        if (not self.usable(connection, row, fingerprint) or row["local_customer_id"] != intent["local_customer_id"]
                or row["revision"] != intent.get("assignment_revision") or actor["email"] not in self.roster(row)):
            return False
        binding = connection.execute("SELECT * FROM billing_job_documents WHERE company_id=? AND realm_id=? AND environment=? AND document_type=? AND local_document_id=?",
                                     (*scope(intent), intent["document_type"], intent["local_document_id"])).fetchone()
        if binding is None:
            return intent["operation"] == "create"
        return binding["service_call_id"] == intent["service_call_id"] and binding["local_customer_id"] == intent["local_customer_id"]

    def bind_document(self, connection, intent):
        if not intent.get("service_call_id"):
            return
        key = (*scope(intent), intent["document_type"], intent["local_document_id"])
        binding = connection.execute("SELECT * FROM billing_job_documents WHERE company_id=? AND realm_id=? AND environment=? AND document_type=? AND local_document_id=?", key).fetchone()
        if binding is not None and (binding["service_call_id"] != intent["service_call_id"] or binding["local_customer_id"] != intent["local_customer_id"]):
            raise failure("job_changed", "Keep this billing document with its original job and customer.")
        connection.execute("INSERT OR IGNORE INTO billing_job_documents VALUES (?,?,?,?,?,?,?)", (*key, intent["service_call_id"], intent["local_customer_id"]))

    def public(self, connection, row, fingerprint):
        return {"companyID": row["company_id"], "realmID": row["realm_id"], "environment": row["environment"],
                "serviceCallID": row["service_call_id"], "localCustomerID": row["local_customer_id"],
                "revision": row["revision"], "technicianEmails": self.roster(row), "enabled": bool(row["enabled"]),
                "usable": bool(self.usable(connection, row, fingerprint)), "updatedAt": row["updated_at"]}

    def read(self, session_id, payload):
        if not isinstance(payload, dict) or set(payload) != {"companyID", "realmID", "environment", "serviceCallID"}:
            raise failure("invalid_request", "Choose one job in its original workspace.", 400)
        intent = request_scope(payload)
        with self.database() as connection:
            actor, fingerprint = self.context(connection, session_id, intent)
            row = self.record(connection, intent)
            if actor["role"] not in ("Admin", "Dispatcher"):
                if (actor["role"] != "Field Technician" or not self.usable(connection, row, fingerprint)
                        or actor["email"] not in self.roster(row)):
                    raise failure("access_denied", "Current access to this job is required.", 403)
            return {"assignment": self.public(connection, row, fingerprint) if row is not None else None}

    def save(self, session_id, payload):
        required = {"companyID", "realmID", "environment", "serviceCallID", "localCustomerID", "technicianEmails", "enabled", "expectedRevision", "operationID"}
        if not isinstance(payload, dict) or set(payload) != required:
            raise failure("invalid_request", "Use the supported job billing assignment fields only.", 400)
        intent = request_scope(payload)
        customer = canonical_uuid(payload["localCustomerID"])
        operation = canonical_uuid(payload["operationID"])
        roster = roster_values(payload["technicianEmails"])
        expected = payload["expectedRevision"]
        if type(payload["enabled"]) is not bool or (payload["enabled"] and not roster) or type(expected) is not int or not 0 <= expected < 2147483647:
            raise failure("invalid_request", "Review the job roster, access choice and original revision.", 400)
        normalized = {**intent, "customer": customer, "roster": roster, "enabled": payload["enabled"], "expected": expected}
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, fingerprint = self.context(connection, session_id, intent, office=True)
            row = self.record(connection, intent)
            previous = connection.execute("SELECT * FROM billing_assignment_mutations WHERE company_id=? AND realm_id=? AND environment=? AND operation_id=?", (*scope(intent), operation)).fetchone()
            if previous is not None:
                try:
                    saved = json.loads(self.decrypt(previous["payload_ciphertext"]) or "")
                except (ValueError, TypeError):
                    raise failure("storage_unavailable", "The original assignment change could not be verified.", 503) from None
                if saved != normalized or previous["grant_fingerprint"] != fingerprint:
                    raise failure("assignment_conflict", "The saved assignment operation no longer matches this change.")
                if row is None or row["revision"] != previous["revision"]:
                    raise failure("assignment_conflict", "A newer assignment exists. Review it without replacing it with the old edit.")
                return {"assignment": self.public(connection, row, fingerprint)}
            if (row["revision"] if row else 0) != expected:
                raise failure("assignment_conflict", "Another dispatcher changed this job. Review the current assignment first.")
            if row is not None and row["local_customer_id"] != customer:
                raise failure("job_changed", "A job's billing authority must retain its original customer.")
            if payload["enabled"]:
                for email in roster:
                    user = connection.execute("SELECT role,is_active FROM users WHERE email=?", (email,)).fetchone()
                    if user is None or not user["is_active"] or user["role"] != "Field Technician":
                        raise failure("invalid_roster", "Choose active field technicians with current business accounts.", 400)
            revision = expected + 1
            # Hash randomized authenticated ciphertext, not the low-entropy
            # roster. A plaintext roster hash could enumerate small crews from
            # a stolen database even without the encryption key.
            ciphertext = self.encrypt(canonical({"scope": [*scope(intent), intent["service_call_id"]],
                                                "customer": customer, "revision": revision, "roster": roster}))
            connection.execute("""INSERT INTO billing_job_assignments VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(company_id,realm_id,environment,service_call_id) DO UPDATE SET
                revision=excluded.revision,roster_ciphertext=excluded.roster_ciphertext,roster_hash=excluded.roster_hash,
                enabled=excluded.enabled,grant_fingerprint=excluded.grant_fingerprint,approved_by=excluded.approved_by,updated_at=excluded.updated_at""",
                (*scope(intent), intent["service_call_id"], customer, revision, ciphertext, digest(ciphertext),
                 int(payload["enabled"]), fingerprint, actor["email"], self.now().isoformat()))
            connection.execute("INSERT INTO billing_assignment_mutations VALUES (?,?,?,?,?,?,?,?)",
                               (*scope(intent), operation, intent["service_call_id"], self.encrypt(canonical(normalized)), revision, fingerprint))
            self.audit(actor["email"], "assign" if payload["enabled"] else "revoke", "billing-job", intent["service_call_id"], connection=connection)
            return {"assignment": self.public(connection, self.record(connection, intent), fingerprint)}
