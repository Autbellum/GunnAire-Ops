"""Encrypted, owner-only full-model source; independent of core-field-v1.

No staff projection, CloudKit permission, local-store adoption, financial action,
or provider write is granted by this archival ledger. Operations are immutable;
deletions retain original fields and can only be explicitly restored.
"""
from __future__ import annotations

import hashlib
from cryptography.fernet import InvalidToken

try:
    from Backend import cloudkit_staff_shares as sharing, staff_workspace_contract as contract, qbo_change_capture
except ModuleNotFoundError:
    import cloudkit_staff_shares as sharing
    import staff_workspace_contract as contract
    import qbo_change_capture


SCHEMA = """
CREATE TABLE IF NOT EXISTS staff_workspace_source_heads (
 company_id TEXT NOT NULL, environment TEXT NOT NULL, replica_id TEXT NOT NULL, schema_version TEXT NOT NULL,
 sequence INTEGER NOT NULL CHECK(sequence >= 0),
 PRIMARY KEY(company_id,environment,replica_id,schema_version)
);
CREATE TABLE IF NOT EXISTS staff_workspace_source_records (
 company_id TEXT NOT NULL, environment TEXT NOT NULL, replica_id TEXT NOT NULL, schema_version TEXT NOT NULL,
 kind TEXT NOT NULL, record_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0),
 deleted INTEGER NOT NULL CHECK(deleted IN (0,1)), ciphertext TEXT NOT NULL,
 PRIMARY KEY(company_id,environment,replica_id,schema_version,kind,record_id)
);
CREATE TABLE IF NOT EXISTS staff_workspace_source_operations (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, environment TEXT NOT NULL, replica_id TEXT NOT NULL,
 schema_version TEXT NOT NULL, actor_email TEXT NOT NULL, request_hash TEXT NOT NULL, ciphertext TEXT NOT NULL
);
"""
WHERE = "company_id=? AND environment=? AND replica_id=? AND schema_version=?"


def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)


class StaffWorkspaceSource:
    def __init__(self, shares):
        self.shares = shares

    def scope(self, connection, session_id, payload):
        company, environment = sharing.scope(payload)
        expected_replica = sharing.identifier(payload.get("replicaID"))
        actor = self.shares.actor(connection, session_id)
        if actor["role"] != "Admin":
            raise sharing.fail("owner_required", "Only an active business administrator can access original owner records.", 403)
        binding = self.shares.binding(connection, company, environment)
        if binding["replica_id"] != expected_replica:
            raise sharing.fail("replica_changed", "Verify the original approved owner workspace before recovering this request.", 409)
        return actor, (company, environment, expected_replica, contract.SCHEMA_VERSION)

    @staticmethod
    def metadata(scope):
        return dict(companyID=scope[0], environment=scope[1], replicaID=scope[2], schema=scope[3], schemaDigest=contract.SCHEMA_DIGEST)

    @staticmethod
    def unavailable():
        return sharing.fail("storage_unavailable", "Original owner storage could not be verified. Keep saved local work and pending requests for recovery.", 503)

    @staticmethod
    def sequence(connection, scope):
        row = connection.execute("SELECT sequence FROM staff_workspace_source_heads WHERE " + WHERE, scope).fetchone()
        return contract.integer(row["sequence"]) if row else 0

    def encode(self, value):
        try:
            raw = contract.wire(value)
            ciphertext = self.shares.encrypt(raw)
            if type(ciphertext) is not str or not ciphertext or ciphertext == raw:
                raise ValueError()
            return ciphertext
        except (ValueError, TypeError, RuntimeError):
            raise self.unavailable() from None

    def decode(self, ciphertext):
        try:
            return qbo_change_capture.strict_json(self.shares.decrypt(ciphertext))
        except (InvalidToken, ValueError, TypeError, RuntimeError, RecursionError):
            raise self.unavailable() from None

    def decode_record(self, row):
        try:
            value = self.decode(row["ciphertext"])
            contract.exact(value, "companyID environment replicaID schema schemaDigest kind id revision deleted fields")
            scope = tuple(row[name] for name in ("company_id", "environment", "replica_id", "schema_version"))
            if any(value[name] != expected for name, expected in self.metadata(scope).items()):
                raise ValueError()
            if (value["kind"], value["id"], value["revision"], value["deleted"]) != (row["kind"], row["record_id"], row["revision"], bool(row["deleted"])):
                raise ValueError()
            sharing.identifier(value["id"])
            contract.integer(value["revision"], 1)
            if type(value["deleted"]) is not bool:
                raise ValueError()
            contract.validate(value["kind"], value["fields"])
            return value
        except (sharing.AttemptError, ValueError, TypeError, KeyError):
            raise self.unavailable() from None

    def apply(self, session_id, payload):
        contract.exact(payload, "companyID environment replicaID schema schemaDigest operationID expectedSequence changes")
        if payload["schema"] != contract.SCHEMA_VERSION or payload["schemaDigest"] != contract.SCHEMA_DIGEST:
            raise sharing.fail("schema_changed", "Use a matching app and backend owner schema. Retain the original request unchanged.", 409)
        operation = sharing.identifier(payload["operationID"])
        base = contract.integer(payload["expectedSequence"])
        if type(payload["changes"]) is not list or not 1 <= len(payload["changes"]) <= 100:
            raise contract.invalid()
        seen = set()
        for change in payload["changes"]:
            contract.change(change)
            key = (change["kind"], change["id"])
            if key in seen:
                raise sharing.fail("duplicate_record", "Change each original record at most once per batch.", 400)
            seen.add(key)
        raw = contract.canonical(payload).encode()
        if len(raw) > contract.MAX_BATCH_BYTES:
            raise contract.invalid()
        request_hash = hashlib.sha256(raw).hexdigest()
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope = self.scope(connection, session_id, payload)
            current = self.sequence(connection, scope)
            old = connection.execute("SELECT * FROM staff_workspace_source_operations WHERE id=?", (operation,)).fetchone()
            expected_changes = [dict(kind=c["kind"], id=c["id"], revision=c["expectedRevision"] + 1, deleted=c["action"] == "delete") for c in payload["changes"]]
            receipt = dict(**self.metadata(scope), operationID=operation, sequence=base + 1, changes=expected_changes)
            if old:
                if (tuple(old[name] for name in ("company_id", "environment", "replica_id", "schema_version")) != scope
                        or old["actor_email"] != actor["email"] or old["request_hash"] != request_hash):
                    raise sharing.fail("operation_changed", "Recover the exact original operation without replacing its identity, owner, or contents.", 409)
                recovered = self.decode(old["ciphertext"])
                # Compare canonical bytes to reject bool/int substitution and
                # bind encrypted receipts to the exact operation and actor.
                expected = dict(receipt=receipt, actorEmail=actor["email"], requestHash=request_hash)
                if contract.canonical(recovered) != contract.canonical(expected) or base + 1 > current:
                    raise self.unavailable()
                return {**receipt, "currentSequence": current}
            if current != base:
                raise sharing.fail("source_changed", "Newer owner work exists. Reconcile without discarding the original request.", 409)
            next_sequence = contract.integer(current + 1, 1)
            new_count = 0
            for change in payload["changes"]:
                key = scope + (change["kind"], change["id"])
                previous = connection.execute("SELECT * FROM staff_workspace_source_records WHERE " + WHERE + " AND kind=? AND record_id=?", key).fetchone()
                if (previous["revision"] if previous else 0) != change["expectedRevision"]:
                    raise sharing.fail("record_changed", "A saved record changed. Keep the original local edit for reconciliation.", 409)
                old_value = self.decode_record(previous) if previous else None
                action = change["action"]
                deleted = bool(previous["deleted"]) if previous else False
                if (action in ("delete", "restore") and previous is None or action == "restore" and not deleted
                        or action in ("upsert", "delete") and deleted):
                    raise sharing.fail("deletion_changed", "Review the original deletion before changing or restoring this record.", 409)
                value = dict(**self.metadata(scope), kind=change["kind"], id=change["id"],
                             revision=contract.integer(change["expectedRevision"] + 1, 1), deleted=action == "delete",
                             fields=old_value["fields"] if action == "delete" else change["fields"])
                connection.execute("INSERT OR REPLACE INTO staff_workspace_source_records VALUES (?,?,?,?,?,?,?,?,?)",
                                   (*key, value["revision"], int(value["deleted"]), self.encode(value)))
                new_count += int(previous is None)
            # Include retained tombstones in the bound. Never silently prune an
            # original or create a source that cannot be read for reconciliation.
            if new_count and connection.execute("SELECT COUNT(*) AS n FROM staff_workspace_source_records WHERE " + WHERE, scope).fetchone()["n"] > contract.MAX_RECORDS:
                raise sharing.fail("source_capacity", "Owner history requires coordinated archival review. Original work was retained.", 409)
            rows = connection.execute("SELECT SUM(LENGTH(ciphertext)) AS n FROM staff_workspace_source_records WHERE " + WHERE, scope).fetchone()
            if rows["n"] > contract.MAX_SCAN_BYTES:
                raise sharing.fail("source_capacity", "Owner history requires coordinated archival review. Original work was retained.", 409)
            connection.execute("INSERT INTO staff_workspace_source_heads VALUES (?,?,?,?,?) ON CONFLICT(company_id,environment,replica_id,schema_version) DO UPDATE SET sequence=excluded.sequence", (*scope, next_sequence))
            saved = self.encode(dict(receipt=receipt, actorEmail=actor["email"], requestHash=request_hash))
            connection.execute("INSERT INTO staff_workspace_source_operations VALUES (?,?,?,?,?,?,?,?)", (operation, *scope, actor["email"], request_hash, saved))
            self.shares.audit(actor["email"], "apply-owner-source-batch", "staff-workspace-source", operation, connection=connection)
            return {**receipt, "currentSequence": next_sequence}

    def source_page(self, session_id, payload):
        required = {"companyID", "environment", "replicaID"}
        if type(payload) is not dict or set(payload) not in (required, required | {"sequence"}, required | {"sequence", "after"}):
            raise contract.invalid()
        after = payload.get("after")
        parts = ["", ""]
        if after is not None:
            if type(after) is not str:
                raise contract.invalid()
            parts = after.split(":")
            if len(parts) != 2 or parts[0] not in contract.SPECS:
                raise contract.invalid()
            sharing.identifier(parts[1])
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope = self.scope(connection, session_id, payload)
            sequence = self.sequence(connection, scope)
            if "sequence" in payload and str(sequence) != payload["sequence"]:
                raise sharing.fail("source_changed", "The owner source advanced. Restart this read without discarding pending edits.", 409)
            rows = connection.execute("SELECT * FROM staff_workspace_source_records WHERE " + WHERE + " AND (kind,record_id)>(?,?) ORDER BY kind,record_id LIMIT 101", (*scope, *parts)).fetchall()
            result = dict(**self.metadata(scope), sequence=sequence, records=[], nextCursor=None)
            size = len(contract.wire(result).encode()) + 256
            for row in rows[:100]:
                record = self.decode_record(row)
                added = len(contract.wire(record).encode()) + 1
                if size + added > contract.MAX_PAGE_BYTES:
                    break
                result["records"].append(record)
                size += added
            if rows and not result["records"]:
                raise self.unavailable()
            if len(rows) > len(result["records"]):
                last = result["records"][-1]
                result["nextCursor"] = last["kind"] + ":" + last["id"]
            self.shares.audit(actor["email"], "read-owner-source-page", "staff-workspace-source", scope[2], connection=connection)
            return result
