"""Durable staff operational command journal + HTTP receipt after acceptance.

Commands require prepared selection content and the same selection/source/content
binding used by media. Only OPERATIONS-policy scalar fields present in the
accepted view's `fields` partition may be commanded. Never mutates mounted
content bytes; never flips operationalWorkspaceReady; never invents defaults.
"""
from __future__ import annotations

import copy

try:
    from Backend import staff_workspace_delivery as delivery
    from Backend import staff_workspace_field_policy as field_policy
    from Backend import staff_workspace_contract as contract
    from Backend import qbo_change_capture
except ModuleNotFoundError:
    import staff_workspace_delivery as delivery
    import staff_workspace_field_policy as field_policy
    import staff_workspace_contract as contract
    import qbo_change_capture

sharing = delivery.sharing
SCHEMA = "staff-workspace-operational-command-v1"
REQUEST_FIELDS = (
    delivery.SCOPE_FIELDS
    + " schema commandID selectionID sourceSequence contentSHA256"
    + " recordKind recordID expectedRevision fieldName value"
)
OPERATIONS = {kind: frozenset(names.split()) for kind, names in field_policy.OPERATIONS.items()}


def initialize_schema(connection):
    connection.execute("""CREATE TABLE IF NOT EXISTS staff_workspace_commands (
        command_id TEXT PRIMARY KEY,
        selection_id TEXT NOT NULL,
        share_id TEXT NOT NULL,
        actor_email TEXT NOT NULL,
        schema TEXT NOT NULL,
        source_sequence INTEGER NOT NULL,
        content_sha256 TEXT NOT NULL,
        record_kind TEXT NOT NULL,
        record_id TEXT NOT NULL,
        expected_revision INTEGER NOT NULL,
        field_name TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at TEXT NOT NULL
    )""")


def validate_value(kind, field_name, value):
    if kind not in contract.SPECS or field_name not in contract.SPECS[kind]:
        raise ValueError()
    spec = contract.SPECS[kind][field_name]
    if type(value) is not dict or len(value) != 1:
        raise ValueError()
    if value == {"null": {}}:
        if not spec.get("nullable", False):
            raise ValueError()
        return value
    tag = spec["type"]
    # Structured JSON evidence is never commanded as a raw scalar write here.
    if field_name.endswith("JSON") or tag not in ("text", "flag", "integer", "number", "date", "identifier"):
        raise ValueError()
    contract.exact(value, tag)
    contract.exact(value[tag], "_0")
    atom = value[tag]["_0"]
    if tag == "text":
        if type(atom) is not str or "\0" in atom or len(atom.encode("utf-8")) > 1_048_576:
            raise ValueError()
        if "enumeration" in spec and atom not in spec["enumeration"]:
            raise ValueError()
    elif tag == "integer":
        if type(atom) is not int or not -2_147_483_647 <= atom <= 2_147_483_647:
            raise ValueError()
    elif tag in ("number", "date"):
        import math
        bound = 1e12 if tag == "number" else 1e11
        if type(atom) not in (int, float) or not -bound <= atom <= bound or not math.isfinite(atom):
            raise ValueError()
    elif tag == "flag":
        if type(atom) is not bool:
            raise ValueError()
    elif tag == "identifier":
        if type(atom) is not str:
            raise ValueError()
        sharing.identifier(atom)
    return value


class StaffWorkspaceCommands(delivery.StaffWorkspaceDelivery):
    @staticmethod
    def recorded_receipt(request, actor_email, created_at):
        fields = "schema commandID selectionID sourceSequence contentSHA256 recordKind recordID expectedRevision fieldName value"
        return dict(**{key: copy.deepcopy(request[key]) for key in fields.split()}, actorEmail=actor_email,
                    createdAt=created_at, state="recorded", operationalWorkspaceReady=False)

    def submit(self, session_id, share_id, operation, payload):
        contract.exact(payload, REQUEST_FIELDS)
        if payload["schema"] != SCHEMA:
            raise sharing.fail("schema_changed", "Use the supported staff operational command schema.", 409)
        command_id = sharing.identifier(payload["commandID"])
        selection_id = sharing.identifier(payload["selectionID"])
        if selection_id != operation:
            raise sharing.fail("invalid_request", "Command selectionID must match the prepared selection path.", 400)
        record_kind = payload["recordKind"]
        record_id = sharing.identifier(payload["recordID"])
        field_name = payload["fieldName"]
        if type(record_kind) is not str or record_kind not in OPERATIONS:
            raise sharing.fail("command_field_unavailable", "Only operations-policy record kinds may be commanded.", 403)
        if type(field_name) is not str or field_name not in OPERATIONS[record_kind]:
            raise sharing.fail("command_field_unavailable", "Only operations-policy fields may be commanded.", 403)
        if field_name.endswith("JSON"):
            raise sharing.fail("command_field_unavailable", "Structured JSON fields are not scalar command targets.", 403)
        contract.integer(payload["sourceSequence"], 1)
        contract.integer(payload["expectedRevision"], 1)
        if type(payload["contentSHA256"]) is not str or len(payload["contentSHA256"]) != 64:
            raise sharing.fail("invalid_request", "Command content digest is invalid.", 400)
        try:
            value = validate_value(record_kind, field_name, payload["value"])
        except (sharing.AttemptError, ValueError, TypeError, KeyError):
            raise sharing.fail("invalid_request", "Command value must match the owner field scalar type.", 400) from None

        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            initialize_schema(connection)
            actor, scope, share = self.selection.member_authority(connection, session_id, share_id, payload)
            role = share["member_role"]
            if not field_policy.allows("operations", role, False):
                raise sharing.fail("command_forbidden", "Current staff role cannot submit operations commands.", 403)
            row = connection.execute(
                "SELECT * FROM staff_workspace_selections WHERE id=? AND share_id=?",
                (operation, share_id)).fetchone()
            snapshot = self.selection.shared_original(row, scope, share)
            sequence = self.source.sequence(connection, scope)
            self.selection.receipt(snapshot, sequence)
            if payload["sourceSequence"] != snapshot["sourceSequence"]:
                raise sharing.fail("source_changed", "Command sourceSequence must match the accepted selection.", 409)
            raw = self.original(connection, operation, snapshot)
            if raw is None:
                raise sharing.fail("content_not_prepared", "Prepare the original full content before commanding fields.", 404)
            digest = delivery.digest(raw)
            if payload["contentSHA256"] != digest:
                raise sharing.fail("content_changed", "Command content digest must match the prepared operational content.", 409)
            view = qbo_change_capture.strict_json(raw.decode("utf-8"))
            record = next((item for item in view["records"]
                           if item["kind"] == record_kind and item["id"] == record_id), None)
            if record is None:
                raise sharing.fail("command_record_unavailable", "This record is not part of the prepared operational content.", 404)
            if record["revision"] != payload["expectedRevision"]:
                raise sharing.fail("revision_conflict", "expectedRevision no longer matches the prepared record revision.", 409)
            contract.exact(record["body"], "operational")
            contract.exact(record["body"]["operational"], "_0")
            partition = record["body"]["operational"]["_0"]
            contract.exact(partition, "fields unavailableFields structuredFields")
            fields = partition["fields"]
            unavailable = partition["unavailableFields"]
            structured = partition["structuredFields"]
            if type(fields) is not dict or type(unavailable) is not dict or type(structured) is not dict:
                raise sharing.fail("command_field_unavailable", "Operational field partition is invalid.", 503)
            if field_name in unavailable or field_name in structured or field_name not in fields:
                raise sharing.fail(
                    "command_field_unavailable",
                    "Only operations-policy scalars present in the accepted fields partition may be commanded.", 403)
            # Idempotent journal by commandID — same body returns same receipt.
            existing = connection.execute(
                "SELECT * FROM staff_workspace_commands WHERE command_id=?", (command_id,)).fetchone()
            request_body = dict(
                schema=SCHEMA,
                companyID=payload["companyID"],
                environment=payload["environment"],
                replicaID=payload["replicaID"],
                commandID=command_id,
                selectionID=selection_id,
                sourceSequence=payload["sourceSequence"],
                contentSHA256=digest,
                recordKind=record_kind,
                recordID=record_id,
                expectedRevision=payload["expectedRevision"],
                fieldName=field_name,
                value=copy.deepcopy(value),
            )
            canonical_request = contract.canonical(request_body)
            if existing is not None:
                if existing["actor_email"] != actor["email"]:
                    raise sharing.fail("command_actor_changed", "Recover this command using its original business account.", 403)
                saved = self.source.decode(existing["payload"])
                try:
                    contract.exact(saved, "request receipt")
                except (sharing.AttemptError, ValueError, TypeError):
                    raise self.source.unavailable() from None
                if contract.canonical(saved["request"]) != canonical_request:
                    raise sharing.fail(
                        "command_conflict",
                        "A different command body was already recorded for this commandID.", 409)
                expected_columns = (selection_id, share_id, SCHEMA, payload["sourceSequence"], digest,
                                    record_kind, record_id, payload["expectedRevision"], field_name)
                columns = "selection_id share_id schema source_sequence content_sha256 record_kind record_id expected_revision field_name"
                receipt = self.recorded_receipt(request_body, actor["email"], existing["created_at"])
                if tuple(existing[key] for key in columns.split()) != expected_columns or contract.canonical(saved["receipt"]) != contract.canonical(receipt):
                    raise self.source.unavailable()
                self.shares.audit(actor["email"], "recover-operational-command", "staff-workspace-selection", operation, connection=connection)
                return receipt
            # An exact original receipt is recoverable after unrelated source
            # progress. It is not a new mutation or permission to rebase the
            # technician's intent. Fresh actor/share/content checks still ran.
            if sequence != snapshot["sourceSequence"]:
                raise sharing.fail("source_changed", "Refresh full company data before submitting a field command.", 409)
            created_at = self.shares.now().isoformat()
            receipt = self.recorded_receipt(request_body, actor["email"], created_at)
            stored = dict(request=request_body, receipt=receipt)
            encrypted = self.source.encode(stored)
            connection.execute(
                """INSERT INTO staff_workspace_commands
                   (command_id, selection_id, share_id, actor_email, schema, source_sequence,
                    content_sha256, record_kind, record_id, expected_revision, field_name, payload, created_at)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (command_id, selection_id, share_id, actor["email"], SCHEMA, payload["sourceSequence"],
                 digest, record_kind, record_id, payload["expectedRevision"], field_name,
                 encrypted, created_at))
            self.shares.audit(actor["email"], "submit-operational-command", "staff-workspace-selection",
                              operation, connection=connection)
            return receipt
