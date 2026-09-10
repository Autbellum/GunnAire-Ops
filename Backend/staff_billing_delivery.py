"""Durable, owner-only billing content bound to one full-workspace selection.

This is one field-adapter's output, not complete staff workspace delivery.
Current server authority gates every action; advancing the owner source stops
content pages while preserving recovery of the original receipt.
"""
from __future__ import annotations

import hashlib

try:
    from Backend import staff_workspace_contract as contract, staff_workspace_source as source
    from Backend import staff_workspace_selection as selection, staff_workspace_selections as selections
    from Backend import staff_billing_projection as billing, cloudkit_staff_shares as sharing
except ModuleNotFoundError:
    import staff_workspace_contract as contract
    import staff_workspace_source as source
    import staff_workspace_selection as selection
    import staff_workspace_selections as selections
    import staff_billing_projection as billing
    import cloudkit_staff_shares as sharing

SCHEMA = "staff-billing-delivery-v1"
PAGE_BYTES = 6 * 1024 * 1024
PAGE_COUNT = 100
SCOPE_FIELDS = "companyID environment replicaID"
VIEW_FIELDS = "schema companyID environment replicaID membershipID memberRevision shareRevision projectionPolicy sourceSequence documents"


def initialize_schema(connection):
    connection.execute("""CREATE TABLE IF NOT EXISTS staff_billing_projections (
        selection_id TEXT PRIMARY KEY, content_sha256 TEXT NOT NULL, ciphertext TEXT NOT NULL
    )""")


def digest(value):
    return hashlib.sha256(contract.canonical(value).encode()).hexdigest()


def key(document):
    return document["kind"] + ":" + document["id"].lower()


class StaffBillingDelivery:
    def __init__(self, shares):
        self.selection = selections.StaffWorkspaceSelections(shares)
        self.shares, self.source = shares, self.selection.source

    def authority(self, connection, session_id, share_id, operation, scope):
        sharing.identifier(operation)
        actor, scope, share = self.selection.authority(connection, session_id, share_id, scope)
        row = connection.execute("SELECT * FROM staff_workspace_selections WHERE id=?", (operation,)).fetchone()
        snapshot = self.selection.original(row, scope, share, actor)
        sequence = self.source.sequence(connection, scope)
        self.selection.receipt(snapshot, sequence)  # Detect source-head rollback.
        return actor, scope, snapshot, sequence

    def original(self, connection, operation, snapshot):
        row = connection.execute("SELECT * FROM staff_billing_projections WHERE selection_id=?", (operation,)).fetchone()
        if row is None:
            return None
        saved = self.source.decode(row["ciphertext"])
        try:
            contract.exact(saved, "selectionSHA256 projection")
            if saved["selectionSHA256"] != self.selection.digest(snapshot):
                raise ValueError()
            view = saved["projection"]
            contract.exact(view, VIEW_FIELDS)
            expected = {name: snapshot[name] for name in VIEW_FIELDS.split() if name not in ("schema", "documents")}
            expected["schema"] = billing.SCHEMA
            if any(view[name] != value or type(view[name]) is not type(value) for name, value in expected.items()):
                raise ValueError()
            if type(view["documents"]) is not list or len(view["documents"]) > 20_000:
                raise ValueError()
            expected_keys = [r["kind"] + ":" + r["id"] for r in snapshot["records"] if r["kind"] in ("invoice", "estimate")]
            if [key(doc) for doc in view["documents"]] != expected_keys:
                raise ValueError()
            if len(contract.wire(view).encode()) > billing.MAX_BYTES or digest(view) != row["content_sha256"]:
                raise ValueError()
            return view
        except (sharing.AttemptError, ValueError, TypeError, KeyError, AttributeError):
            raise self.source.unavailable() from None

    def receipt(self, view, snapshot, sequence):
        return dict(schema=SCHEMA, contentSchema=billing.SCHEMA, selectionID=snapshot["operationID"],
                    **{name: view[name] for name in VIEW_FIELDS.split() if name not in ("schema", "documents")},
                    selectionSHA256=self.selection.digest(snapshot), contentSHA256=digest(view),
                    sourceCoverage=sorted(contract.SPECS), coverage=["estimate", "invoice"],
                    documentCount=len(view["documents"]), currentSourceSequence=sequence,
                    sourceCurrent=sequence == view["sourceSequence"], operationalWorkspaceReady=False,
                    fieldProjectionRequired=True, localCloudKitProofRequired=True)

    def prepare(self, session_id, share_id, operation, payload):
        contract.exact(payload, SCOPE_FIELDS + " contentSchema")
        if payload["contentSchema"] != billing.SCHEMA:
            raise sharing.fail("schema_changed", "Use the supported billing content schema.", 409)
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope, snapshot, sequence = self.authority(connection, session_id, share_id, operation, payload)
            view = self.original(connection, operation, snapshot)
            if view is None:
                if sequence != snapshot["sourceSequence"]:
                    raise sharing.fail("source_changed", "Prepare a current full-workspace selection before its billing content.", 409)
                totals = connection.execute("SELECT COUNT(*) AS n,COALESCE(SUM(LENGTH(ciphertext)),0) AS bytes FROM staff_workspace_source_records WHERE " + source.WHERE, scope).fetchone()
                if totals["n"] > contract.MAX_RECORDS or totals["bytes"] > contract.MAX_SCAN_BYTES:
                    raise selection.failure("source_capacity")
                records = [self.source.decode_record(row) for row in connection.execute(
                    "SELECT * FROM staff_workspace_source_records WHERE " + source.WHERE + " ORDER BY kind,record_id", scope)]
                graph = selection.Graph(records)
                index = graph.index(snapshot["memberRole"], connection.execute(
                    "SELECT member_email FROM cloudkit_staff_shares WHERE id=?", (share_id,)).fetchone()[0])
                # Detect changed records/assignments without a corresponding head
                # update. Never silently reinterpret the immutable selection.
                if index != snapshot["records"]:
                    raise self.source.unavailable()
                view = billing.prepare(graph, index, snapshot)
                encrypted = self.source.encode(dict(selectionSHA256=self.selection.digest(snapshot), projection=view))
                connection.execute("INSERT INTO staff_billing_projections VALUES (?,?,?)", (operation, digest(view), encrypted))
                self.shares.audit(actor["email"], "prepare-staff-billing", "staff-billing-projection", operation, connection=connection)
            return self.receipt(view, snapshot, sequence)

    def read(self, session_id, share_id, operation, query, *, documents=False):
        required = set(SCOPE_FIELDS.split())
        if type(query) is not dict or set(query) not in (required, required | {"after"}) or not documents and "after" in query:
            raise contract.invalid()
        after = query.get("after")
        if after is not None:
            if type(after) is not str or after.count(":") != 1:
                raise contract.invalid()
            kind, identity = after.split(":")
            if kind not in ("invoice", "estimate"):
                raise contract.invalid()
            sharing.identifier(identity)
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope, snapshot, sequence = self.authority(connection, session_id, share_id, operation, query)
            view = self.original(connection, operation, snapshot)
            if view is None:
                raise sharing.fail("billing_not_prepared", "Prepare billing content using this original selection first.", 404)
            result = self.receipt(view, snapshot, sequence)
            if documents:
                if sequence != snapshot["sourceSequence"]:
                    raise sharing.fail("source_changed", "The original source advanced. Prepare current content before reading billing data.", 409)
                keys = [key(doc) for doc in view["documents"]]
                if after is not None and after not in keys:
                    raise sharing.fail("invalid_cursor", "Continue with the original billing content cursor.", 400)
                start = keys.index(after) + 1 if after else 0
                indexes = {r["kind"] + ":" + r["id"]: r for r in snapshot["records"]}
                page, record_index = [], []
                result.update(projection=dict(view, documents=page), recordIndex=record_index, nextCursor=None)
                for document in view["documents"][start:start + PAGE_COUNT]:
                    page.append(document)
                    record_index.append(indexes[key(document)])
                    result["nextCursor"] = key(document) if start + len(page) < len(keys) else None
                    if len(contract.wire(result).encode()) > PAGE_BYTES:
                        page.pop(); record_index.pop()
                        if not page:
                            raise selection.failure("source_capacity")
                        result["nextCursor"] = key(page[-1])
                        break
            self.shares.audit(actor["email"], "read-staff-billing", "staff-billing-projection", operation, connection=connection)
            return result
