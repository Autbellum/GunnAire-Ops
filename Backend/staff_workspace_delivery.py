"""Immutable full-field preparation for the original administrator, not staff access.

Persist the exact UTF-8 payload and hash those bytes once. Chunk transport never
asks Swift to reproduce Python's number spelling or JSON canonicalization.
Every request rechecks current membership, creator, scope and source authority.
"""
from __future__ import annotations

import base64
import hashlib

try:
    from Backend import staff_workspace_contract as contract, staff_workspace_source as source
    from Backend import staff_workspace_selection as selection, staff_workspace_projection as projection
    from Backend import staff_billing_delivery as billing_delivery, cloudkit_staff_shares as sharing
    from Backend import qbo_change_capture
except ModuleNotFoundError:
    import staff_workspace_contract as contract
    import staff_workspace_source as source
    import staff_workspace_selection as selection
    import staff_workspace_projection as projection
    import staff_billing_delivery as billing_delivery
    import cloudkit_staff_shares as sharing
    import qbo_change_capture

SCHEMA = "staff-workspace-delivery-v1"
CHUNK_BYTES = 1024 * 1024
SCOPE_FIELDS = "companyID environment replicaID"
IDENTITY_FIELDS = "companyID environment replicaID membershipID memberRevision memberRole shareRevision projectionPolicy sourceSequence"


def initialize_schema(connection):
    connection.execute("""CREATE TABLE IF NOT EXISTS staff_workspace_projections (
        selection_id TEXT PRIMARY KEY, content_sha256 TEXT NOT NULL, ciphertext TEXT NOT NULL
    )""")
    if "seal_sha256" not in {row[1] for row in connection.execute("PRAGMA table_info(staff_workspace_projections)")}:
        connection.execute("ALTER TABLE staff_workspace_projections ADD COLUMN seal_sha256 TEXT")
    connection.execute("""CREATE TABLE IF NOT EXISTS staff_workspace_cloud_seals (
        selection_id TEXT PRIMARY KEY, ciphertext TEXT NOT NULL
    )""")
    try:
        from Backend import staff_workspace_commands as commands
    except ModuleNotFoundError:
        import staff_workspace_commands as commands
    commands.initialize_schema(connection)


def header(snapshot):
    return dict(**{key: snapshot[key] for key in IDENTITY_FIELDS.split()},
                schema=projection.SCHEMA, sourceSchema=contract.SCHEMA_VERSION,
                sourceSchemaDigest=contract.SCHEMA_DIGEST, fieldPolicy=projection.policy.VERSION,
                discriminatorSchema=projection.discriminators.VERSION,
                structuredSchema=projection.STRUCTURED_SCHEMA, billingSchema=projection.billing.SCHEMA,
                coverage=sorted(contract.SPECS))


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


class StaffWorkspaceDelivery(billing_delivery.StaffBillingDelivery):
    def original(self, connection, operation, snapshot):
        row = connection.execute("SELECT * FROM staff_workspace_projections WHERE selection_id=?", (operation,)).fetchone()
        if row is None:
            return None
        saved = self.source.decode(row["ciphertext"])
        try:
            contract.exact(saved, "selectionSHA256 payloadBase64")
            if saved["selectionSHA256"] != self.selection.digest(snapshot):
                raise ValueError()
            encoded = saved["payloadBase64"]
            if type(encoded) is not str or len(encoded) > 4 * ((projection.MAX_BYTES + 2) // 3):
                raise ValueError()
            raw = base64.b64decode(encoded, validate=True)
            if not 0 < len(raw) <= projection.MAX_BYTES or base64.b64encode(raw).decode("ascii") != encoded:
                raise ValueError()
            if digest(raw) != row["content_sha256"]:
                raise ValueError()
            view = qbo_change_capture.strict_json(raw.decode("utf-8"))
            expected = header(snapshot)
            contract.exact(view, " ".join(expected) + " records")
            if any(view[key] != value or type(view[key]) is not type(value) for key, value in expected.items()):
                raise ValueError()
            if type(view["records"]) is not list or len(view["records"]) != len(snapshot["records"]):
                raise ValueError()
            for record, original in zip(view["records"], snapshot["records"]):
                contract.exact(record, "kind id revision unavailableLinks body")
                if contract.canonical({k: record[k] for k in original}) != contract.canonical(original):
                    raise ValueError()
                branch = "billing" if original["kind"] in ("invoice", "estimate") else "operational"
                contract.exact(record["body"], branch)
                contract.exact(record["body"][branch], "_0")
                if type(record["body"][branch]["_0"]) is not dict:
                    raise ValueError()
            return raw
        except (sharing.AttemptError, ValueError, TypeError, KeyError, AttributeError, UnicodeDecodeError, RecursionError):
            raise self.source.unavailable() from None

    def receipt(self, raw, snapshot, sequence):
        return dict(schema=SCHEMA, contentSchema=projection.SCHEMA, selectionID=snapshot["operationID"],
                    **{key: snapshot[key] for key in IDENTITY_FIELDS.split()},
                    selectionSHA256=self.selection.digest(snapshot), contentSHA256=digest(raw),
                    sourceSchema=contract.SCHEMA_VERSION, sourceSchemaDigest=contract.SCHEMA_DIGEST,
                    fieldPolicy=projection.policy.VERSION, discriminatorSchema=projection.discriminators.VERSION,
                    structuredSchema=projection.STRUCTURED_SCHEMA, billingSchema=projection.billing.SCHEMA,
                    coverage=sorted(contract.SPECS), recordCount=len(snapshot["records"]),
                    payloadBytes=len(raw), chunkBytes=CHUNK_BYTES, currentSourceSequence=sequence,
                    sourceCurrent=sequence == snapshot["sourceSequence"], operationalWorkspaceReady=False,
                    fieldProjectionRequired=False, localCloudKitProofRequired=True)

    def prepare(self, session_id, share_id, operation, payload):
        contract.exact(payload, SCOPE_FIELDS + " contentSchema")
        if payload["contentSchema"] != projection.SCHEMA:
            raise sharing.fail("schema_changed", "Use the supported full-workspace content schema.", 409)
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope, snapshot, sequence = self.authority(connection, session_id, share_id, operation, payload)
            raw = self.original(connection, operation, snapshot)
            if raw is None:
                if sequence != snapshot["sourceSequence"]:
                    raise sharing.fail("source_changed", "Prepare a current full-workspace selection before its content.", 409)
                totals = connection.execute("SELECT COUNT(*) AS n,COALESCE(SUM(LENGTH(ciphertext)),0) AS bytes FROM staff_workspace_source_records WHERE " + source.WHERE, scope).fetchone()
                if totals["n"] > contract.MAX_RECORDS or totals["bytes"] > contract.MAX_SCAN_BYTES:
                    raise selection.failure("source_capacity")
                records = [self.source.decode_record(row) for row in connection.execute(
                    "SELECT * FROM staff_workspace_source_records WHERE " + source.WHERE + " ORDER BY kind,record_id", scope)]
                graph = selection.Graph(records)
                email = connection.execute("SELECT member_email FROM cloudkit_staff_shares WHERE id=?", (share_id,)).fetchone()[0]
                if graph.index(snapshot["memberRole"], email) != snapshot["records"]:
                    raise self.source.unavailable()
                view = projection.prepare(graph, snapshot["records"], snapshot, email)
                raw = contract.wire(view).encode("utf-8")
                encrypted = self.source.encode(dict(selectionSHA256=self.selection.digest(snapshot),
                                                    payloadBase64=base64.b64encode(raw).decode("ascii")))
                connection.execute("INSERT INTO staff_workspace_projections (selection_id,content_sha256,ciphertext) VALUES (?,?,?)",
                                   (operation, digest(raw), encrypted))
                self.shares.audit(actor["email"], "prepare-staff-workspace", "staff-workspace-projection", operation, connection=connection)
            return self.receipt(raw, snapshot, sequence)

    def read(self, session_id, share_id, operation, query, *, chunks=False):
        expected = set(SCOPE_FIELDS.split()) | ({"offset"} if chunks else set())
        if type(query) is not dict or set(query) != expected:
            raise contract.invalid()
        offset = query.get("offset", "0")
        # Canonical decimal spelling, fixed boundaries and a bounded parse.
        if type(offset) is not str or not offset.isascii() or not offset.isdigit() or len(offset) > 8:
            raise contract.invalid()
        number = int(offset)
        if str(number) != offset or number % CHUNK_BYTES or number >= projection.MAX_BYTES:
            raise contract.invalid()
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope, snapshot, sequence = self.authority(connection, session_id, share_id, operation, query)
            raw = self.original(connection, operation, snapshot)
            if raw is None:
                raise sharing.fail("content_not_prepared", "Prepare content using this original selection first.", 404)
            result = self.receipt(raw, snapshot, sequence)
            if chunks:
                if sequence != snapshot["sourceSequence"]:
                    raise sharing.fail("source_changed", "The source advanced. Prepare current content before reading workspace data.", 409)
                if number >= len(raw):
                    raise sharing.fail("invalid_cursor", "Continue with an original content chunk offset.", 400)
                chunk = raw[number:number + CHUNK_BYTES]
                end = number + len(chunk)
                result.update(offset=number, nextOffset=end if end < len(raw) else None,
                              chunkSHA256=digest(chunk), payloadBase64=base64.b64encode(chunk).decode("ascii"))
            self.shares.audit(actor["email"], "read-staff-workspace", "staff-workspace-projection", operation, connection=connection)
            return result
