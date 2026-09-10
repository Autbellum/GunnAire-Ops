"""Immutable encrypted owner-side record-selection operations for all 32 kinds.

These paged indexes contain no business field values. They are a prerequisite
to full role-safe projection, not a staff data endpoint or a workspace lease.
"""
from __future__ import annotations

import hashlib

try:
    from Backend import cloudkit_staff_shares as sharing, staff_workspace_contract as contract
    from Backend import staff_workspace_source as source, staff_workspace_selection as selection
except ModuleNotFoundError:
    import cloudkit_staff_shares as sharing
    import staff_workspace_contract as contract
    import staff_workspace_source as source
    import staff_workspace_selection as selection


SCHEMA = """
CREATE TABLE IF NOT EXISTS staff_workspace_selections (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, environment TEXT NOT NULL, replica_id TEXT NOT NULL,
 share_id TEXT NOT NULL, actor_email TEXT NOT NULL, request_hash TEXT NOT NULL, ciphertext TEXT NOT NULL
);
"""
PAGE_SIZE = 100
MAX_SNAPSHOT_BYTES = 32 * 1024 * 1024


def initialize_schema(connection):
    connection.execute(SCHEMA)


class StaffWorkspaceSelections:
    def __init__(self, shares):
        self.shares = shares
        self.source = source.StaffWorkspaceSource(shares)

    def authority(self, connection, session_id, share_id, payload):
        actor, scope = self.source.scope(connection, session_id, payload)
        sharing.identifier(share_id)
        row = connection.execute("SELECT * FROM cloudkit_staff_shares WHERE id=?", (share_id,)).fetchone()
        self.shares.authorize_row(connection, actor, row, scope[0], scope[1])
        if row["projection_policy"] != sharing.POLICIES.get(row["member_role"]):
            raise sharing.fail("sharing_changed", "The saved projection policy does not match the current staff role. Review the original invitation.", 403)
        current = self.shares.public(connection, row)
        if not current["businessAccessEligible"] or current["reviewRequired"] or current["cloudKitRevocationRequired"]:
            raise sharing.fail("sharing_changed", "Current staff sharing authority is required before preparing company data.", 403)
        return actor, scope, row

    @staticmethod
    def metadata(scope, share):
        return dict(schema=selection.VERSION, sourceSchema=contract.SCHEMA_VERSION, sourceSchemaDigest=contract.SCHEMA_DIGEST,
                    companyID=scope[0], environment=scope[1], replicaID=scope[2], membershipID=share["id"],
                    memberRevision=share["member_revision"], memberRole=share["member_role"], projectionPolicy=share["projection_policy"],
                    shareRevision=share["revision"], coverage=sorted(contract.SPECS), fieldProjectionRequired=True,
                    operationalWorkspaceReady=False, localCloudKitProofRequired=True)

    @staticmethod
    def digest(snapshot):
        return hashlib.sha256(contract.canonical(snapshot).encode()).hexdigest()

    def receipt(self, snapshot, sequence):
        if sequence < snapshot["sourceSequence"]:
            raise self.source.unavailable()
        return {key: value for key, value in snapshot.items() if key != "records"} | {
            "recordCount": len(snapshot["records"]), "snapshotSHA256": self.digest(snapshot),
            "currentSourceSequence": sequence, "sourceCurrent": snapshot["sourceSequence"] == sequence}

    def member_authority(self, connection, session_id, share_id, payload):
        """Staff-capable share authority. Never uses Admin-only owner source.scope."""
        company, environment = sharing.scope(payload)
        expected_replica = sharing.identifier(payload.get("replicaID"))
        actor = self.shares.actor(connection, session_id)
        binding = self.shares.binding(connection, company, environment)
        if binding["replica_id"] != expected_replica:
            raise sharing.fail("replica_changed", "Verify the original approved owner workspace before recovering this request.", 409)
        sharing.identifier(share_id)
        row = connection.execute("SELECT * FROM cloudkit_staff_shares WHERE id=?", (share_id,)).fetchone()
        self.shares.authorize_row(connection, actor, row, company, environment)
        if row["projection_policy"] != sharing.POLICIES.get(row["member_role"]):
            raise sharing.fail("sharing_changed", "The saved projection policy does not match the current staff role. Review the original invitation.", 403)
        current = self.shares.public(connection, row)
        if not current["businessAccessEligible"] or current["reviewRequired"] or current["cloudKitRevocationRequired"]:
            raise sharing.fail("sharing_changed", "Current staff sharing authority is required before preparing company data.", 403)
        return actor, (company, environment, expected_replica, contract.SCHEMA_VERSION), row

    def shared_original(self, row, scope, share):
        """Decode a selection bound to the share without requiring preparer identity."""
        if row is None or tuple(row[key] for key in ("company_id", "environment", "replica_id", "share_id")) != (
                *scope[:3], share["id"]):
            raise sharing.fail("selection_not_found", "This original selection is not available for the current staff share.", 404)
        saved = self.source.decode(row["ciphertext"])
        try:
            contract.exact(saved, "requestHash actorEmail snapshot")
            if saved["requestHash"] != row["request_hash"] or saved["actorEmail"] != row["actor_email"]:
                raise ValueError()
            snapshot = saved["snapshot"]
            expected = self.metadata(scope, share)
            contract.exact(snapshot, " ".join(expected) + " operationID sourceSequence records")
            if any(snapshot[key] != value or type(snapshot[key]) is not type(value) for key, value in expected.items()):
                raise sharing.fail("sharing_changed", "The original membership or projection policy changed. Keep its original operation for review.", 403)
            if snapshot["operationID"] != row["id"]:
                raise ValueError()
            contract.integer(snapshot["sourceSequence"], 1)
            if type(snapshot["records"]) is not list or len(snapshot["records"]) > 20_000:
                raise ValueError()
            keys = []
            rules = selection.rules()
            for record in snapshot["records"]:
                contract.exact(record, "kind id revision unavailableLinks")
                if record["kind"] not in rules:
                    raise ValueError()
                sharing.identifier(record["id"])
                contract.integer(record["revision"], 1)
                names = record["unavailableLinks"]
                if type(names) is not list or any(type(name) is not str for name in names) or names != sorted(set(names)):
                    raise ValueError()
                if not set(names) <= set(rules[record["kind"]]) | set(selection.LISTS.get(record["kind"], {})):
                    raise ValueError()
                keys.append(record["kind"] + ":" + record["id"])
            if keys != sorted(set(keys)) or len(contract.wire(snapshot).encode()) > MAX_SNAPSHOT_BYTES:
                raise ValueError()
            return snapshot
        except sharing.AttemptError as error:
            if error.code == "sharing_changed":
                raise
            raise self.source.unavailable() from None
        except (KeyError, ValueError, TypeError):
            raise self.source.unavailable() from None

    def original(self, row, scope, share, actor):
        if row is None or tuple(row[key] for key in ("company_id", "environment", "replica_id", "share_id", "actor_email")) != (
                *scope[:3], share["id"], actor["email"]):
            raise sharing.fail("selection_not_found", "This original selection is not available to the current owner.", 404)
        saved = self.source.decode(row["ciphertext"])
        try:
            contract.exact(saved, "requestHash actorEmail snapshot")
            if saved["requestHash"] != row["request_hash"] or saved["actorEmail"] != actor["email"]:
                raise ValueError()
            snapshot = saved["snapshot"]
            expected = self.metadata(scope, share)
            contract.exact(snapshot, " ".join(expected) + " operationID sourceSequence records")
            if any(snapshot[key] != value or type(snapshot[key]) is not type(value) for key, value in expected.items()):
                raise sharing.fail("sharing_changed", "The original membership or projection policy changed. Keep its original operation for review.", 403)
            if snapshot["operationID"] != row["id"]:
                raise ValueError()
            contract.integer(snapshot["sourceSequence"], 1)
            if type(snapshot["records"]) is not list or len(snapshot["records"]) > 20_000:
                raise ValueError()
            keys = []
            rules = selection.rules()
            for record in snapshot["records"]:
                contract.exact(record, "kind id revision unavailableLinks")
                if record["kind"] not in rules:
                    raise ValueError()
                sharing.identifier(record["id"])
                contract.integer(record["revision"], 1)
                names = record["unavailableLinks"]
                if type(names) is not list or any(type(name) is not str for name in names) or names != sorted(set(names)):
                    raise ValueError()
                if not set(names) <= set(rules[record["kind"]]) | set(selection.LISTS.get(record["kind"], {})):
                    raise ValueError()
                keys.append(record["kind"] + ":" + record["id"])
            if keys != sorted(set(keys)) or len(contract.wire(snapshot).encode()) > MAX_SNAPSHOT_BYTES:
                raise ValueError()
            return snapshot
        except sharing.AttemptError as error:
            if error.code == "sharing_changed":
                raise
            raise self.source.unavailable() from None
        except (KeyError, ValueError, TypeError):
            raise self.source.unavailable() from None

    def prepare(self, session_id, share_id, payload):
        contract.exact(payload, "companyID environment replicaID operationID expectedSourceSequence expectedShareRevision sourceSchemaDigest")
        operation = sharing.identifier(payload["operationID"])
        expected_sequence = contract.integer(payload["expectedSourceSequence"], 1)
        expected_revision = contract.integer(payload["expectedShareRevision"], 1)
        if payload["sourceSchemaDigest"] != contract.SCHEMA_DIGEST:
            raise sharing.fail("schema_changed", "Use the matching full owner workspace schema.", 409)
        request_hash = hashlib.sha256(contract.canonical(payload).encode()).hexdigest()
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope, share = self.authority(connection, session_id, share_id, payload)
            sequence = self.source.sequence(connection, scope)
            old = connection.execute("SELECT * FROM staff_workspace_selections WHERE id=?", (operation,)).fetchone()
            if old:
                snapshot = self.original(old, scope, share, actor)
                if old["request_hash"] != request_hash:
                    raise sharing.fail("operation_changed", "Recover the exact original selection without replacing its request.", 409)
                return self.receipt(snapshot, sequence)
            if share["revision"] != expected_revision:
                raise sharing.fail("sharing_changed", "The staff invitation changed before selection.", 409)
            if sequence != expected_sequence:
                raise sharing.fail("source_changed", "The full owner source changed. Retain the original request and refresh its source.", 409)
            totals = connection.execute("SELECT COUNT(*) AS n,COALESCE(SUM(LENGTH(ciphertext)),0) AS bytes FROM staff_workspace_source_records WHERE " + source.WHERE, scope).fetchone()
            if totals["n"] > contract.MAX_RECORDS or totals["bytes"] > contract.MAX_SCAN_BYTES:
                raise selection.failure("source_capacity")
            originals = [self.source.decode_record(row) for row in connection.execute(
                "SELECT * FROM staff_workspace_source_records WHERE " + source.WHERE + " ORDER BY kind,record_id", scope)]
            records = selection.Graph(originals).index(share["member_role"], share["member_email"])
            snapshot = dict(**self.metadata(scope, share), operationID=operation, sourceSequence=sequence, records=records)
            if len(contract.wire(snapshot).encode()) > MAX_SNAPSHOT_BYTES:
                raise selection.failure("source_capacity")
            saved = self.source.encode(dict(requestHash=request_hash, actorEmail=actor["email"], snapshot=snapshot))
            connection.execute("INSERT INTO staff_workspace_selections VALUES (?,?,?,?,?,?,?,?)",
                               (operation, *scope[:3], share_id, actor["email"], request_hash, saved))
            self.shares.audit(actor["email"], "prepare-full-selection", "staff-workspace-selection", operation, connection=connection)
            return self.receipt(snapshot, sequence)

    def read(self, session_id, share_id, operation, query, *, records=False):
        required = {"companyID", "environment", "replicaID"}
        if type(query) is not dict or set(query) not in (required, required | {"after"}) or not records and "after" in query:
            raise contract.invalid()
        sharing.identifier(operation)
        after = query.get("after")
        if after is not None:
            if type(after) is not str or after.count(":") != 1:
                raise contract.invalid()
            kind, key = after.split(":")
            if kind not in contract.SPECS:
                raise contract.invalid()
            sharing.identifier(key)
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope, share = self.authority(connection, session_id, share_id, query)
            row = connection.execute("SELECT * FROM staff_workspace_selections WHERE id=?", (operation,)).fetchone()
            snapshot = self.original(row, scope, share, actor)
            sequence = self.source.sequence(connection, scope)
            receipt = self.receipt(snapshot, sequence)
            if records:
                # No stale assignment index is usable after any owner change.
                # Its original receipt stays recoverable; data pages do not.
                if sequence != snapshot["sourceSequence"]:
                    raise sharing.fail("source_changed", "The original source advanced. Prepare a new selection before projecting fields.", 409)
                keys = [record["kind"] + ":" + record["id"] for record in snapshot["records"]]
                if after is not None and after not in keys:
                    raise sharing.fail("invalid_cursor", "Continue with the original selection cursor.", 400)
                start = keys.index(after) + 1 if after else 0
                page = snapshot["records"][start:start + PAGE_SIZE]
                receipt |= dict(records=page, nextCursor=keys[start + len(page) - 1] if start + len(page) < len(keys) else None)
                if len(contract.wire(receipt).encode()) > contract.MAX_PAGE_BYTES:
                    raise selection.failure("source_capacity")
            self.shares.audit(actor["email"], "read-full-selection", "staff-workspace-selection", operation, connection=connection)
            return receipt
