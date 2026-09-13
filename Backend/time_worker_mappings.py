"""Company-scoped, administrator-reviewed QBO worker identity for approved time.

Accounting can read a usable mapping but cannot change it. No method creates,
edits, or deletes an Employee, Vendor, TimeActivity, or payroll record in QBO.
Local technician references are never silently imported into a different realm.
"""
from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone

try:
    from Backend.catalog_publications import canonical, failure, scope
    from Backend.billing_assignments import connection_revision
    from Backend.payment_attempts import canonical_uuid, grant_fingerprint, reference, AttemptError
except ModuleNotFoundError:
    from catalog_publications import canonical, failure, scope
    from billing_assignments import connection_revision
    from payment_attempts import canonical_uuid, grant_fingerprint, reference, AttemptError


SCHEMA = """
CREATE TABLE IF NOT EXISTS time_worker_mappings (
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 worker_email TEXT NOT NULL, revision INTEGER NOT NULL,
 payload_ciphertext TEXT NOT NULL, payload_hash TEXT NOT NULL,
 grant_fingerprint TEXT NOT NULL, approved_by TEXT NOT NULL, updated_at TEXT NOT NULL,
 PRIMARY KEY(company_id,realm_id,environment,worker_email)
);
CREATE TABLE IF NOT EXISTS time_worker_mapping_mutations (
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 operation_id TEXT NOT NULL, worker_email TEXT NOT NULL, request_hash TEXT NOT NULL,
 result_ciphertext TEXT NOT NULL, grant_fingerprint TEXT NOT NULL, actor_email TEXT NOT NULL,
 PRIMARY KEY(company_id,realm_id,environment,operation_id)
);
"""


def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def email(value):
    if (not isinstance(value, str) or len(value) > 254 or value != value.strip().lower()
            or not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", value)
            or any(ord(char) < 32 or ord(char) == 127 for char in value)):
        raise failure("invalid_worker", "Choose one registered business team member.", 400)
    return value


def epoch(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise failure("invalid_request", "Refresh the original business connection and worker review.", 400)
    return value


def worker_reference(value, kind, identifier):
    """Whitelist display identity, not tax IDs, compensation, addresses or notes."""
    if kind not in ("Employee", "Vendor") or not isinstance(value, dict):
        raise failure("worker_unconfirmed", "QuickBooks did not confirm this worker.")
    reference(identifier)
    name, token = value.get("DisplayName"), value.get("SyncToken")
    if (value.get("Id") != identifier or value.get("Active") is not True
            or not isinstance(name, str) or not name.strip() or len(name) > 500
            or any(ord(char) < 32 or ord(char) == 127 for char in name)):
        raise failure("worker_unconfirmed", "Review the active worker's name and ID in this QuickBooks company.")
    reference(token)
    return {"kind": kind, "providerID": identifier, "displayName": name,
            "referenceRevision": digest(["time-worker-reference-v1", kind, identifier, token, name, True])}


class TimeWorkerMappings:
    def __init__(self, database, provider_factory, encrypt, decrypt, audit, now=None):
        self.database, self.provider_factory, self.encrypt, self.decrypt, self.audit = database, provider_factory, encrypt, decrypt, audit
        self.now = now or (lambda: datetime.now(timezone.utc))

    def actor(self, connection, session_id, *, administrator=False):
        actor = connection.execute("SELECT s.*,u.role,u.is_active FROM auth_sessions s JOIN users u ON u.email=s.email WHERE s.id=?",
                                   (session_id,)).fetchone()
        try:
            issued = datetime.fromisoformat(actor["created_at"].replace("Z", "+00:00"))
            expires = datetime.fromisoformat(actor["expires_at"].replace("Z", "+00:00"))
            roles = ("Admin",) if administrator else ("Admin", "Accounting")
            valid = (actor["is_active"] == 1 and actor["role"] in roles and actor["revoked_at"] is None
                     and issued.tzinfo is not None and expires.tzinfo is not None and issued <= self.now() < expires)
        except (TypeError, ValueError):
            valid = False
        if not valid:
            raise failure("administrator_required" if administrator else "office_required",
                          "Current administrator access is required to change worker mappings." if administrator else
                          "Current accounting or administrator access is required to review team time.", 403)
        return actor

    def authorize(self, connection, session_id, intent, *, administrator=False):
        actor = self.actor(connection, session_id, administrator=administrator)
        company = connection.execute("SELECT company_id FROM company_identity WHERE singleton=1").fetchone()
        if company is None or company[0] != intent["company_id"]:
            raise failure("company_changed", "Reopen the original business workspace.", 403)
        # Inactive former staff remain valid historical time identities. Their
        # inactive status never grants login or approval authority.
        if connection.execute("SELECT 1 FROM users WHERE email=?", (intent["worker_email"],)).fetchone() is None:
            raise failure("worker_missing", "Register this team member in the business before mapping time.", 409)
        grant = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
        if grant is None:
            raise failure("provider_changed", "Ask the administrator to connect the business to QuickBooks.")
        reference(grant["realm_id"])
        if grant["environment"] not in ("sandbox", "production"):
            raise failure("provider_changed", "Review the original QuickBooks environment.")
        if "realm_id" in intent and (grant["realm_id"] != intent["realm_id"] or grant["environment"] != intent["environment"]):
            raise failure("provider_changed", "Reopen this worker in the original QuickBooks company.")
        fingerprint = grant_fingerprint(grant)
        if "connection_revision" in intent and intent["connection_revision"] != connection_revision(fingerprint):
            raise failure("grant_changed", "QuickBooks was reconnected. Review this worker mapping again.")
        return actor, {**dict(grant), "grant_fingerprint": fingerprint}

    def record(self, connection, intent):
        return connection.execute("SELECT * FROM time_worker_mappings WHERE company_id=? AND realm_id=? AND environment=? AND worker_email=?",
                                  (*scope(intent), intent["worker_email"])).fetchone()

    def public(self, connection, row, fingerprint):
        if row is None:
            return None
        try:
            value = json.loads(self.decrypt(row["payload_ciphertext"]) or "")
            if (not isinstance(value, dict) or set(value) != {"scope", "worker", "revision", "reference", "enabled"}
                    or value["scope"] != list(scope(row)) or value["worker"] != row["worker_email"]
                    or value["revision"] != row["revision"] or type(value["enabled"]) is not bool
                    or digest(value) != row["payload_hash"]):
                raise ValueError()
            ref = value["reference"]
            if (not isinstance(ref, dict) or set(ref) != {"kind", "providerID", "displayName", "referenceRevision"}
                    or ref["kind"] not in ("Employee", "Vendor") or not isinstance(ref["displayName"], str)
                    or not ref["displayName"].strip() or len(ref["displayName"]) > 500):
                raise ValueError()
            reference(ref["providerID"]); epoch(ref["referenceRevision"])
        except (ValueError, TypeError, AttemptError):
            raise failure("storage_unavailable", "The original worker mapping could not be verified.", 503) from None
        approver = connection.execute("SELECT role,is_active FROM users WHERE email=?", (row["approved_by"],)).fetchone()
        usable = (value["enabled"] and row["grant_fingerprint"] == fingerprint and approver is not None
                  and approver["is_active"] == 1 and approver["role"] == "Admin")
        return {"companyID": row["company_id"], "realmID": row["realm_id"], "environment": row["environment"],
                "workerEmail": row["worker_email"], "revision": row["revision"], **ref,
                "enabled": value["enabled"], "usable": bool(usable), "updatedAt": row["updated_at"]}

    def context(self, session_id, payload, *, candidate=False):
        fields = {"companyID", "workerEmail"} | ({"kind", "providerID"} if candidate else set())
        if not isinstance(payload, dict) or set(payload) != fields:
            raise failure("invalid_query", "Choose one business team member and original worker reference.", 400)
        intent = {"company_id": canonical_uuid(payload["companyID"]), "worker_email": email(payload["workerEmail"])}
        if candidate and payload["kind"] not in ("Employee", "Vendor"):
            raise failure("invalid_worker", "Choose Employee or Vendor.", 400)
        if candidate:
            reference(payload["providerID"])
        with self.database() as connection:
            _, grant = self.authorize(connection, session_id, intent, administrator=candidate)
            intent.update(realm_id=grant["realm_id"], environment=grant["environment"],
                          connection_revision=connection_revision(grant["grant_fingerprint"]))
            row = self.record(connection, intent)
            mapping = self.public(connection, row, grant["grant_fingerprint"])

        def check():
            with self.database() as connection:
                _, fresh = self.authorize(connection, session_id, intent, administrator=candidate)
                if self.public(connection, self.record(connection, intent), fresh["grant_fingerprint"]) != mapping:
                    raise failure("mapping_changed", "The shared worker mapping changed. Refresh this review.")

        selected = None
        if candidate:
            selected = worker_reference(self.provider_factory(grant, check).read(payload["kind"], payload["providerID"]),
                                        payload["kind"], payload["providerID"])
        check()
        return {"companyID": intent["company_id"], "workerEmail": intent["worker_email"],
                "realmID": intent["realm_id"], "environment": intent["environment"], "protocolVersion": 1,
                "connectionRevision": intent["connection_revision"], "mapping": mapping, "candidate": selected}

    def save(self, session_id, payload):
        required = {"companyID", "realmID", "environment", "workerEmail", "connectionRevision", "operationID",
                    "expectedRevision", "kind", "providerID", "referenceRevision", "enabled"}
        if not isinstance(payload, dict) or set(payload) != required:
            raise failure("invalid_request", "Use the reviewed worker mapping fields only.", 400)
        expected = payload["expectedRevision"]
        if (type(expected) is not int or not 0 <= expected < 2147483647 or type(payload["enabled"]) is not bool
                or payload["kind"] not in ("Employee", "Vendor") or payload["environment"] not in ("sandbox", "production")):
            raise failure("invalid_request", "Review the worker type, mapping revision and access choice.", 400)
        intent = {"company_id": canonical_uuid(payload["companyID"]), "realm_id": reference(payload["realmID"]),
                  "environment": payload["environment"], "worker_email": email(payload["workerEmail"]),
                  "connection_revision": epoch(payload["connectionRevision"])}
        identifier = reference(payload["providerID"])
        reviewed = epoch(payload["referenceRevision"])
        operation = canonical_uuid(payload["operationID"])
        request_hash = digest(payload)

        def check(connection):
            actor, grant = self.authorize(connection, session_id, intent, administrator=True)
            old = connection.execute("SELECT * FROM time_worker_mapping_mutations WHERE company_id=? AND realm_id=? AND environment=? AND operation_id=?",
                                     (*scope(intent), operation)).fetchone()
            if old is not None:
                if (old["worker_email"] != intent["worker_email"] or old["request_hash"] != request_hash
                        or old["actor_email"] != actor["email"] or old["grant_fingerprint"] != grant["grant_fingerprint"]):
                    raise failure("operation_changed", "Recover the original worker mapping operation without changing it.")
                # Return the current mapping, not a stale success that could
                # overwrite a later office change on a recovering device.
                return actor, grant, True
            row = self.record(connection, intent)
            if (row["revision"] if row else 0) != expected:
                raise failure("mapping_changed", "Another office change was saved. Refresh the worker before confirming.")
            return actor, grant, False

        def reauthorize():
            with self.database() as connection:
                check(connection)

        with self.database() as connection:
            actor, grant, replay = check(connection)
            if replay:
                return {"mapping": self.public(connection, self.record(connection, intent), grant["grant_fingerprint"]),
                        "operationID": operation, "replayed": True}
            old_mapping = self.public(connection, self.record(connection, intent), grant["grant_fingerprint"])
        if payload["enabled"]:
            selected = worker_reference(self.provider_factory(grant, reauthorize).read(payload["kind"], identifier), payload["kind"], identifier)
            if selected["referenceRevision"] != reviewed:
                raise failure("worker_changed", "The QuickBooks worker changed after review. Review the current name before confirming.")
        else:
            # Disable the exact original mapping even when its QBO worker is
            # inactive or the provider is unavailable; never remap while disabling.
            if (old_mapping is None or old_mapping["kind"] != payload["kind"] or old_mapping["providerID"] != identifier
                    or old_mapping["referenceRevision"] != reviewed):
                raise failure("mapping_changed", "Disable the original saved worker mapping.")
            selected = {key: old_mapping[key] for key in ("kind", "providerID", "displayName", "referenceRevision")}
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, grant, replay = check(connection)
            if not replay:
                if payload["enabled"]:
                    others = connection.execute("SELECT * FROM time_worker_mappings WHERE company_id=? AND realm_id=? AND environment=? AND worker_email!=?",
                                                (*scope(intent), intent["worker_email"])).fetchall()
                    for other in others:
                        linked = self.public(connection, other, grant["grant_fingerprint"])
                        if linked["enabled"] and linked["kind"] == selected["kind"] and linked["providerID"] == selected["providerID"]:
                            raise failure("worker_identity_conflict", "This QuickBooks worker is already assigned to another team member. Review that mapping first.")
                value = {"scope": list(scope(intent)), "worker": intent["worker_email"], "revision": expected + 1,
                         "reference": selected, "enabled": payload["enabled"]}
                cipher = self.encrypt(canonical(value))
                if not isinstance(cipher, str) or not cipher:
                    raise failure("storage_unavailable", "Secure worker mapping storage is unavailable.", 503)
                connection.execute("INSERT OR REPLACE INTO time_worker_mappings VALUES (?,?,?,?,?,?,?,?,?,?)",
                                   (*scope(intent), intent["worker_email"], expected + 1, cipher, digest(value),
                                    grant["grant_fingerprint"], actor["email"], self.now().isoformat()))
                connection.execute("INSERT INTO time_worker_mapping_mutations VALUES (?,?,?,?,?,?,?,?,?)",
                                   (*scope(intent), operation, intent["worker_email"], request_hash, cipher,
                                    grant["grant_fingerprint"], actor["email"]))
                self.audit(actor["email"], "save" if payload["enabled"] else "disable", "time-worker-mapping", operation, connection=connection)
            result = self.public(connection, self.record(connection, intent), grant["grant_fingerprint"])
        return {"mapping": result, "operationID": operation, "replayed": replay}
