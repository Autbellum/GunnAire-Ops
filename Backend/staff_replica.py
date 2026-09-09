"""Encrypted source ledger and immutable membership-filtered CloudKit payloads.

This service does not write CloudKit, authorize accounting mutations, or unlock
the legacy SwiftData store. The owner client must additionally prove its live
Apple account and share before uploading the exact returned payload. The staff
client must prove accepted Apple access, recheck this authority and atomically
commit the full schema snapshot into a separately registered local replica.
"""
from __future__ import annotations

import base64
import hashlib
import json
from cryptography.fernet import InvalidToken

try:
    from Backend import cloudkit_staff_shares as sharing, staff_replica_contract as contract
except ModuleNotFoundError:
    import cloudkit_staff_shares as sharing
    import staff_replica_contract as contract


MAX_RECORDS = 20_000
MAX_SNAPSHOT_BYTES = 16 * 1024 * 1024
MAX_SOURCE_SCAN_BYTES = 64 * 1024 * 1024
SCHEMA = """
CREATE TABLE IF NOT EXISTS staff_replica_heads (
 company_id TEXT NOT NULL, environment TEXT NOT NULL, replica_id TEXT NOT NULL,
 sequence INTEGER NOT NULL CHECK(sequence >= 0), authorization_sequence INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(company_id,environment,replica_id)
);
CREATE TABLE IF NOT EXISTS staff_replica_records (
 company_id TEXT NOT NULL, environment TEXT NOT NULL, replica_id TEXT NOT NULL,
 kind TEXT NOT NULL, record_id TEXT NOT NULL, revision INTEGER NOT NULL,
 deleted INTEGER NOT NULL CHECK(deleted IN (0,1)), ciphertext TEXT NOT NULL,
 PRIMARY KEY(company_id,environment,replica_id,kind,record_id)
);
CREATE TABLE IF NOT EXISTS staff_replica_operations (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, environment TEXT NOT NULL, replica_id TEXT NOT NULL,
 actor_email TEXT NOT NULL, request_hash TEXT NOT NULL, receipt TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS staff_replica_projections (
 id TEXT PRIMARY KEY, share_id TEXT NOT NULL, actor_email TEXT NOT NULL,
 request_hash TEXT NOT NULL, source_sequence INTEGER NOT NULL,
 payload_hash TEXT NOT NULL, payload_size INTEGER NOT NULL, record_count INTEGER NOT NULL,
 created_at TEXT NOT NULL, ciphertext TEXT NOT NULL, authorization_sequence INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS staff_replica_projection_share ON staff_replica_projections(share_id,source_sequence);
"""


def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)
    for table in ("staff_replica_heads", "staff_replica_projections"):
        if "authorization_sequence" not in {row["name"] for row in connection.execute("PRAGMA table_info(" + table + ")")}:
            connection.execute("ALTER TABLE " + table + " ADD COLUMN authorization_sequence INTEGER NOT NULL DEFAULT 0")
    # An older payload cannot acquire newly introduced authorization evidence.
    # Retain it, invalidate only its authority and require a newly prepared snapshot.
    connection.execute("UPDATE staff_replica_heads SET authorization_sequence=1 WHERE sequence>0 AND authorization_sequence=0")


def canonical(value):
    return json.dumps(value, ensure_ascii=True, allow_nan=False, sort_keys=True, separators=(",", ":"))


def integer(value, *, minimum=0):
    if type(value) is not int or not minimum <= value < 2_147_483_647:
        raise sharing.fail("invalid_request", "Use the last confirmed operational revision.", 400)
    return value


def exact(payload, fields):
    if not isinstance(payload, dict) or set(payload) != set(fields.split()):
        raise sharing.fail("invalid_request", "Use only the original replica request fields.", 400)


class StaffReplica:
    def __init__(self, shares):
        self.shares = shares

    def scope(self, connection, session_id, payload, *, owner=False):
        company, environment = sharing.scope(payload)
        actor = self.shares.actor(connection, session_id)
        if owner and actor["role"] != "Admin":
            raise sharing.fail("owner_required", "Only an active business administrator can publish the approved owner replica.", 403)
        binding = self.shares.binding(connection, company, environment)
        return actor, (company, environment, binding["replica_id"])

    @staticmethod
    def sequence(connection, scope):
        row = connection.execute("SELECT sequence FROM staff_replica_heads WHERE company_id=? AND environment=? AND replica_id=?", scope).fetchone()
        return row["sequence"] if row else 0

    @staticmethod
    def authorization_sequence(connection, scope):
        row = connection.execute("SELECT authorization_sequence FROM staff_replica_heads WHERE company_id=? AND environment=? AND replica_id=?", scope).fetchone()
        return row["authorization_sequence"] if row else 0

    def encode(self, value):
        try:
            ciphertext = self.shares.encrypt(canonical(value))
            if not isinstance(ciphertext, str) or not ciphertext or ciphertext == canonical(value):
                raise ValueError()
            return ciphertext
        except (TypeError, ValueError, RuntimeError):
            raise sharing.fail("storage_unavailable", "Encrypted operational storage is unavailable. Keep the original local work.", 503) from None

    def decode_record(self, row):
        try:
            value = json.loads(self.shares.decrypt(row["ciphertext"]))
            exact(value, "companyID environment replicaID kind id revision deleted fields")
            expected = (row["company_id"], row["environment"], row["replica_id"], row["kind"], row["record_id"], row["revision"], bool(row["deleted"]))
            if tuple(value[name] for name in ("companyID", "environment", "replicaID", "kind", "id", "revision", "deleted")) != expected:
                raise ValueError()
            if type(value["deleted"]) is not bool or type(value["revision"]) is not int:
                raise ValueError()
            contract.validate(value["kind"], value["fields"])
            return value
        except (InvalidToken, ValueError, TypeError, KeyError, RuntimeError, sharing.AttemptError):
            raise sharing.fail("storage_unavailable", "An original operational record could not be verified. It was retained for review.", 503) from None

    def apply(self, session_id, payload):
        exact(payload, "companyID environment operationID expectedSequence changes schema")
        operation = sharing.identifier(payload["operationID"])
        base = integer(payload["expectedSequence"])
        if payload["schema"] != contract.SCHEMA_VERSION or not isinstance(payload["changes"], list) or not 1 <= len(payload["changes"]) <= 100:
            raise sharing.fail("invalid_request", "Send one bounded batch using the supported operational schema.", 400)
        seen = set()
        for change in payload["changes"]:
            exact(change, "kind id expectedRevision action fields")
            sharing.identifier(change["id"])
            integer(change["expectedRevision"])
            if not isinstance(change["kind"], str) or change["kind"] not in contract.SPECS or change["action"] not in ("upsert", "delete", "restore"):
                raise contract.invalid()
            key = (change["kind"], change["id"])
            if key in seen:
                raise sharing.fail("duplicate_record", "A batch can change an original record only once.", 400)
            seen.add(key)
            if change["action"] == "delete":
                if change["fields"] != {}:
                    raise contract.invalid()
            else:
                contract.validate(change["kind"], change["fields"])
            if len(canonical(change).encode()) > 64 * 1024:
                raise contract.invalid()
        request_hash = sharing.digest(payload)
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope = self.scope(connection, session_id, payload, owner=True)
            current = self.sequence(connection, scope)
            old = connection.execute("SELECT * FROM staff_replica_operations WHERE id=?", (operation,)).fetchone()
            if old:
                if (old["company_id"], old["environment"], old["replica_id"]) != scope or old["actor_email"] != actor["email"] or old["request_hash"] != request_hash:
                    raise sharing.fail("operation_changed", "Recover the exact original source batch without replacing its identity or content.")
                try:
                    receipt = json.loads(old["receipt"])
                    exact(receipt, "operationID companyID environment replicaID schema sequence changes")
                    expected_changes = [{"kind": c["kind"], "id": c["id"], "revision": c["expectedRevision"] + 1,
                                         "deleted": c["action"] == "delete"} for c in payload["changes"]]
                    if (receipt["operationID"] != operation or (receipt["companyID"], receipt["environment"], receipt["replicaID"]) != scope
                            or receipt["schema"] != contract.SCHEMA_VERSION or integer(receipt["sequence"], minimum=1) > current
                            or receipt["sequence"] != base + 1 or receipt["changes"] != expected_changes):
                        raise ValueError()
                except (ValueError, TypeError, KeyError, sharing.AttemptError):
                    raise sharing.fail("storage_unavailable", "The original batch receipt needs recovery review. No source records were changed.", 503) from None
                return {**receipt, "currentSequence": current}
            if current != base:
                raise sharing.fail("source_changed", "Newer company work exists. Read and reconcile it before publishing this original batch.")
            next_sequence = integer(current + 1, minimum=1)
            changed = []
            authority_changed = False
            for change in payload["changes"]:
                key = scope + (change["kind"], change["id"])
                previous = connection.execute("SELECT * FROM staff_replica_records WHERE company_id=? AND environment=? AND replica_id=? AND kind=? AND record_id=?", key).fetchone()
                if (previous["revision"] if previous else 0) != change["expectedRevision"]:
                    raise sharing.fail("record_changed", "This record changed. Preserve the original local edit for reconciliation.")
                old_value = self.decode_record(previous) if previous else None
                if (change["action"] in ("delete", "restore") and previous is None or
                        change["action"] == "restore" and not previous["deleted"] or
                        change["action"] == "upsert" and previous is not None and previous["deleted"] or
                        change["action"] == "delete" and previous["deleted"]):
                    raise sharing.fail("deletion_changed", "Review the original deletion before changing or restoring this record.")
                authority_changed = authority_changed or contract.authority_changed(old_value, change["kind"], change["action"], change["fields"])
                value = dict(companyID=scope[0], environment=scope[1], replicaID=scope[2], kind=change["kind"], id=change["id"],
                             revision=integer(change["expectedRevision"] + 1, minimum=1), deleted=change["action"] == "delete",
                             fields=old_value["fields"] if change["action"] == "delete" else change["fields"])
                connection.execute("INSERT OR REPLACE INTO staff_replica_records VALUES (?,?,?,?,?,?,?,?)",
                                   (*key, value["revision"], int(value["deleted"]), self.encode(value)))
                changed.append({name: value[name] for name in ("kind", "id", "revision", "deleted")})
            authorization_sequence = integer(self.authorization_sequence(connection, scope) + int(authority_changed))
            connection.execute("INSERT INTO staff_replica_heads VALUES (?,?,?,?,?) ON CONFLICT(company_id,environment,replica_id) DO UPDATE SET sequence=excluded.sequence,authorization_sequence=excluded.authorization_sequence", (*scope, next_sequence, authorization_sequence))
            receipt = dict(operationID=operation, companyID=scope[0], environment=scope[1], replicaID=scope[2],
                           schema=contract.SCHEMA_VERSION, sequence=next_sequence, changes=changed)
            connection.execute("INSERT INTO staff_replica_operations VALUES (?,?,?,?,?,?,?)", (operation, *scope, actor["email"], request_hash, canonical(receipt)))
            self.shares.audit(actor["email"], "apply-source-batch", "staff-replica", operation, connection=connection)
            return {**receipt, "currentSequence": next_sequence}

    def source_page(self, session_id, payload):
        allowed = {"companyID", "environment", "sequence", "after"}
        if not isinstance(payload, dict) or set(payload) not in (allowed - {"sequence", "after"}, allowed - {"after"}, allowed):
            raise sharing.fail("invalid_query", "Read one consistent operational source revision.", 400)
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope = self.scope(connection, session_id, payload, owner=True)
            sequence = self.sequence(connection, scope)
            if "sequence" in payload and str(sequence) != payload["sequence"]:
                raise sharing.fail("source_changed", "The operational source advanced. Restart this read without discarding pending edits.")
            after = payload.get("after", "")
            parts = after.split(":") if after else ["", ""]
            if after and (len(parts) != 2 or parts[0] not in contract.SPECS):
                raise contract.invalid()
            if after:
                sharing.identifier(parts[1])
            rows = connection.execute("SELECT * FROM staff_replica_records WHERE company_id=? AND environment=? AND replica_id=? AND (kind,record_id)>(?,?) ORDER BY kind,record_id LIMIT 101", (*scope, *parts)).fetchall()
            records = [self.decode_record(row) for row in rows[:100]]
            # Source recovery is owner-only and includes retained tombstone data.
            self.shares.audit(actor["email"], "read-source-page", "staff-replica", scope[2], connection=connection)
            return dict(schema=contract.SCHEMA_VERSION, companyID=scope[0], environment=scope[1], replicaID=scope[2], sequence=sequence,
                        authorizationSequence=self.authorization_sequence(connection, scope),
                        records=records, nextCursor=rows[99]["kind"] + ":" + rows[99]["record_id"] if len(rows) > 100 else None)

    def authority(self, connection, session_id, share_id, payload, *, owner=False):
        actor, scope = self.scope(connection, session_id, payload, owner=owner)
        sharing.identifier(share_id)
        row = connection.execute("SELECT * FROM cloudkit_staff_shares WHERE id=?", (share_id,)).fetchone()
        self.shares.authorize_row(connection, actor, row, scope[0], scope[1])
        public = self.shares.public(connection, row)
        if not public["businessAccessEligible"] or public["reviewRequired"] or public["cloudKitRevocationRequired"]:
            raise sharing.fail("sharing_changed", "Current staff sharing authority is required. Keep existing saved work for review.", 403)
        return actor, scope, row

    def projection(self, session_id, share_id, payload):
        exact(payload, "companyID environment operationID expectedSequence expectedShareRevision")
        operation = sharing.identifier(payload["operationID"])
        integer(payload["expectedSequence"]); integer(payload["expectedShareRevision"], minimum=1)
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope, member = self.authority(connection, session_id, share_id, payload, owner=True)
            sequence = self.sequence(connection, scope)
            authorization_sequence = self.authorization_sequence(connection, scope)
            old = connection.execute("SELECT * FROM staff_replica_projections WHERE id=?", (operation,)).fetchone()
            if old:
                if old["share_id"] != share_id or old["actor_email"] != actor["email"] or old["request_hash"] != sharing.digest(payload):
                    raise sharing.fail("operation_changed", "Recover the original staff snapshot without replacing it.")
                return self.receipt(old, member, sequence, authorization_sequence)
            if payload["expectedSequence"] != sequence or payload["expectedShareRevision"] != member["revision"]:
                raise sharing.fail("source_changed", "The source or original staff invitation changed. Refresh before preparing a snapshot.")
            if sequence == 0:
                raise sharing.fail("source_pending", "The owner has not published operational source data yet.")
            size = connection.execute("SELECT COUNT(*) AS count,COALESCE(SUM(LENGTH(ciphertext)),0) AS bytes FROM staff_replica_records WHERE company_id=? AND environment=? AND replica_id=?", scope).fetchone()
            if size["count"] > MAX_RECORDS or size["bytes"] > MAX_SOURCE_SCAN_BYTES:
                raise sharing.fail("snapshot_too_large", "This operational history needs paginated snapshot packaging; no records were truncated.")
            rows = connection.execute("SELECT * FROM staff_replica_records WHERE company_id=? AND environment=? AND replica_id=? ORDER BY kind,record_id LIMIT ?", (*scope, MAX_RECORDS + 1)).fetchall()
            if len(rows) > MAX_RECORDS:
                raise sharing.fail("snapshot_too_large", "This operational history needs paginated snapshot packaging; no records were truncated.")
            records = contract.selected_records([self.decode_record(row) for row in rows], member)
            value = dict(protocolVersion=1, schema=contract.SCHEMA_VERSION, coverage=contract.COVERAGE, completeForSchema=True,
                         companyID=scope[0], environment=scope[1], replicaID=scope[2], membershipID=share_id,
                         memberRevision=member["member_revision"], projectionPolicy=member["projection_policy"],
                         sourceSequence=sequence, authorizationSequence=authorization_sequence, operationID=operation, records=records)
            raw = canonical(value).encode()
            if len(raw) > MAX_SNAPSHOT_BYTES:
                raise sharing.fail("snapshot_too_large", "This operational history needs paginated snapshot packaging; no records were truncated.")
            connection.execute("INSERT INTO staff_replica_projections VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                               (operation, share_id, actor["email"], sharing.digest(payload), sequence, hashlib.sha256(raw).hexdigest(), len(raw), len(records),
                                self.shares.now().isoformat(), self.encode(value), authorization_sequence))
            self.shares.audit(actor["email"], "prepare-projection", "staff-replica", operation, connection=connection)
            return self.receipt(connection.execute("SELECT * FROM staff_replica_projections WHERE id=?", (operation,)).fetchone(), member, sequence, authorization_sequence)

    @staticmethod
    def receipt(row, member, sequence, authorization_sequence):
        return dict(protocolVersion=1, schema=contract.SCHEMA_VERSION, coverage=contract.COVERAGE,
                    operationID=row["id"], membershipID=member["id"], companyID=member["company_id"], environment=member["environment"],
                    replicaID=member["replica_id"], memberRevision=member["member_revision"], projectionPolicy=member["projection_policy"],
                    sourceSequence=row["source_sequence"], currentSequence=sequence, isCurrent=row["source_sequence"] == sequence,
                    authorizationSequence=row["authorization_sequence"], currentAuthorizationSequence=authorization_sequence,
                    authorizationCurrent=row["authorization_sequence"] > 0 and row["authorization_sequence"] == authorization_sequence,
                    payloadSHA256=row["payload_hash"], payloadBytes=row["payload_size"], recordCount=row["record_count"],
                    createdAt=row["created_at"], localCloudKitProofRequired=True, operationalWorkspaceReady=False)

    def read_projection(self, session_id, share_id, operation_id, payload, *, content=False):
        exact(payload, "companyID environment")
        sharing.identifier(operation_id)
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope, member = self.authority(connection, session_id, share_id, payload, owner=content)
            row = connection.execute("SELECT * FROM staff_replica_projections WHERE id=? AND share_id=?", (operation_id, share_id)).fetchone()
            if row is None:
                raise sharing.fail("not_found", "The original staff snapshot is not available.", 404)
            receipt = self.receipt(row, member, self.sequence(connection, scope), self.authorization_sequence(connection, scope))
            if content:
                if not receipt["authorizationCurrent"]:
                    raise sharing.fail("source_changed", "Assignments or data scope changed. Do not publish this older snapshot.")
                try:
                    raw = self.shares.decrypt(row["ciphertext"]).encode()
                    if len(raw) != row["payload_size"] or hashlib.sha256(raw).hexdigest() != row["payload_hash"]:
                        raise ValueError()
                except (InvalidToken, ValueError, TypeError, RuntimeError):
                    raise sharing.fail("storage_unavailable", "The original staff snapshot could not be verified. It was retained.", 503) from None
                receipt["payloadBase64"] = base64.b64encode(raw).decode()
            self.shares.audit(actor["email"], "read-projection-payload" if content else "read-projection-authority", "staff-replica", operation_id, connection=connection)
            return receipt
