"""Conflict-checked owner application of immutable staff field commands.

Claims serialize owner devices but do not mutate company records. A published
receipt is issued only after the native owner save reaches the full source.
Original staff author/time and a prepared claim survive revocation/restart.
"""
from __future__ import annotations

import copy
import re
from datetime import datetime

try:
    from Backend import staff_workspace_commands as commands, staff_workspace_source as source, staff_owner_field_resolutions as resolutions, staff_owner_field_observations as observations
except ModuleNotFoundError:
    import staff_workspace_commands as commands
    import staff_workspace_source as source
    import staff_owner_field_resolutions as resolutions
    import staff_owner_field_observations as observations

contract, sharing = commands.contract, commands.sharing
SCHEMA = "staff-owner-field-edit-v1"
SCOPE = commands.delivery.SCOPE_FIELDS
PREPARE = SCOPE + " schema commandID operationID ownerStoreID expectedRevision expectedValue reviewedConflict"
CONFIRM = SCOPE + " schema commandID operationID ownerStoreID"


def instant(value):
    if type(value) is not str or re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})", value) is None:
        raise ValueError()
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def initialize_schema(connection):
    resolutions.initialize_schema(connection)
    observations.initialize_schema(connection)
    connection.execute("""CREATE TABLE IF NOT EXISTS staff_owner_field_edit_applications (
        command_id TEXT PRIMARY KEY, operation_id TEXT NOT NULL UNIQUE,
        owner_email TEXT NOT NULL, owner_store_id TEXT NOT NULL, state TEXT NOT NULL,
        ciphertext TEXT NOT NULL
    )""")


class StaffOwnerFieldEdits(observations.StaffOwnerFieldObservations, resolutions.StaffOwnerFieldResolutions, commands.StaffWorkspaceCommands):
    valid_instant = staticmethod(instant)

    @staticmethod
    def valid_owner_email(email):
        if type(email) is not str or email != email.strip().lower() or re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email) is None:
            raise ValueError()
    def command(self, connection, scope, command_id):
        row = connection.execute("""SELECT c.* FROM staff_workspace_commands c
            JOIN staff_workspace_selections s ON s.id=c.selection_id AND s.share_id=c.share_id
            WHERE c.command_id=? AND s.company_id=? AND s.environment=? AND s.replica_id=?""",
            (command_id, *scope[:3])).fetchone()
        if row is None:
            raise sharing.fail("edit_not_found", "This field edit is not in the current company workspace.", 404)
        saved = self.source.decode(row["payload"])
        try:
            contract.exact(saved, "request receipt baseValue" if "baseValue" in saved else "request receipt")
            request = saved["request"]
            contract.exact(request, commands.REQUEST_FIELDS)
            if (request["schema"] != commands.SCHEMA or
                    tuple(request[k] for k in ("companyID", "environment", "replicaID")) != scope[:3]):
                raise ValueError()
            for name in ("commandID", "selectionID", "recordID"):
                sharing.identifier(request[name])
            sharing.account_hash(request["contentSHA256"])
            instant(row["created_at"])
            contract.integer(request["sourceSequence"], 1)
            contract.integer(request["expectedRevision"], 1)
            if (request["recordKind"] not in commands.OPERATIONS or
                    request["fieldName"] not in commands.OPERATIONS[request["recordKind"]]):
                raise ValueError()
            commands.validate_value(request["recordKind"], request["fieldName"], request["value"])
            mapping = {"command_id": "commandID", "selection_id": "selectionID", "schema": "schema",
                       "source_sequence": "sourceSequence", "content_sha256": "contentSHA256", "record_kind": "recordKind",
                       "record_id": "recordID", "expected_revision": "expectedRevision", "field_name": "fieldName"}
            if any(row[column] != request[key] for column, key in mapping.items()):
                raise ValueError()
            if contract.canonical(saved["receipt"]) != contract.canonical(self.recorded_receipt(request, row["actor_email"], row["created_at"])):
                raise ValueError()
            if "baseValue" in saved:
                commands.validate_value(request["recordKind"], request["fieldName"], saved["baseValue"])
        except (sharing.AttemptError, ValueError, TypeError, KeyError):
            raise self.source.unavailable() from None
        return row, saved

    def application(self, connection, command_id):
        row = connection.execute("SELECT * FROM staff_owner_field_edit_applications WHERE command_id=?", (command_id,)).fetchone()
        if row is None:
            return None
        saved = self.source.decode(row["ciphertext"])
        try:
            contract.exact(saved, "request receipt")
            contract.exact(saved["request"], PREPARE)
            receipt = saved["receipt"]
            contract.exact(receipt, "schema commandID operationID ownerStoreID ownerEmail preparedAt expectedRevision expectedValue reviewedConflict state publishedAt")
            for key in ("commandID", "operationID", "ownerStoreID"):
                sharing.identifier(receipt[key])
            sharing.scope(saved["request"])
            sharing.identifier(saved["request"]["replicaID"])
            contract.integer(receipt["expectedRevision"], 1)
            if type(receipt["reviewedConflict"]) is not bool:
                raise ValueError()
            email = receipt["ownerEmail"]
            self.valid_owner_email(email)
            prepared_at = instant(receipt["preparedAt"])
            if receipt["publishedAt"] is not None and instant(receipt["publishedAt"]) < prepared_at:
                raise ValueError()
            _, original = self.command(connection, tuple(saved["request"][key] for key in ("companyID", "environment", "replicaID")), command_id)
            if prepared_at < instant(original["receipt"]["createdAt"]):
                raise ValueError()
            commands.validate_value(original["request"]["recordKind"], original["request"]["fieldName"], receipt["expectedValue"])
            if (receipt["schema"] != SCHEMA or receipt["commandID"] != command_id or
                    receipt["operationID"] != row["operation_id"] or receipt["ownerStoreID"] != row["owner_store_id"] or
                    receipt["ownerEmail"] != row["owner_email"] or receipt["state"] != row["state"] or
                    receipt["state"] not in ("prepared", "published") or
                    (receipt["publishedAt"] is None) != (receipt["state"] == "prepared")):
                raise ValueError()
            for key in ("schema", "commandID", "operationID", "ownerStoreID", "expectedRevision", "expectedValue", "reviewedConflict"):
                if contract.canonical(saved["request"][key]) != contract.canonical(receipt[key]):
                    raise ValueError()
        except (sharing.AttemptError, ValueError, TypeError, KeyError):
            raise self.source.unavailable() from None
        return saved

    def detail(self, connection, session_id, scope, command_id, payload):
        row, saved = self.command(connection, scope, command_id)
        request = saved["request"]
        eligible = True
        try:
            _, _, share = self.selection.authority(connection, session_id, row["share_id"], payload)
            if share["member_email"] != row["actor_email"] or not commands.field_policy.allows("operations", share["member_role"], False):
                eligible = False
            selection = connection.execute("SELECT * FROM staff_workspace_selections WHERE id=?", (row["selection_id"],)).fetchone()
            self.selection.shared_original(selection, scope, share)
        except sharing.AttemptError as error:
            if error.status not in (403, 404, 409):
                raise
            eligible = False
        if "baseValue" not in saved:
            # Legacy encrypted journals predate base-field capture. Recover the
            # original historical selection, never use today's office value.
            selection = connection.execute("SELECT * FROM staff_workspace_selections WHERE id=?", (row["selection_id"],)).fetchone()
            historical = self.source.decode(selection["ciphertext"])["snapshot"]
            historical_share = dict(id=row["share_id"], member_revision=historical["memberRevision"],
                member_role=historical["memberRole"], projection_policy=historical["projectionPolicy"], revision=historical["shareRevision"])
            snapshot = self.selection.shared_original(selection, scope, historical_share)
            raw = self.original(connection, row["selection_id"], snapshot)
            if raw is None or commands.delivery.digest(raw) != request["contentSHA256"]:
                raise self.source.unavailable()
            view = commands.qbo_change_capture.strict_json(raw.decode("utf-8"))
            try:
                record = next(item for item in view["records"] if item["kind"] == request["recordKind"] and item["id"] == request["recordID"])
                base = record["body"]["operational"]["_0"]["fields"][request["fieldName"]]
                commands.validate_value(request["recordKind"], request["fieldName"], base)
            except (StopIteration, KeyError, ValueError, TypeError):
                raise self.source.unavailable() from None
            saved["baseValue"] = base
            connection.execute("UPDATE staff_workspace_commands SET payload=? WHERE command_id=?",
                               (self.source.encode(saved), command_id))
        current_row = connection.execute("SELECT * FROM staff_workspace_source_records WHERE " + source.WHERE + " AND kind=? AND record_id=?",
            (*scope, request["recordKind"], request["recordID"])).fetchone()
        current = None
        if current_row is not None:
            record = self.source.decode_record(current_row)
            current = dict(revision=record["revision"], deleted=record["deleted"], value=record["fields"][request["fieldName"]])
        application = self.application(connection, command_id)
        if application and any(application["request"][k] != request[k] for k in ("companyID", "environment", "replicaID", "commandID")):
            raise self.source.unavailable()
        result = dict(schema=SCHEMA, shareID=row["share_id"], request=request, receipt=saved["receipt"],
                    baseValue=saved["baseValue"], current=current, eligible=eligible,
                    sourceSequence=self.source.sequence(connection, scope), application=application["receipt"] if application else None)
        resolution = self.resolution(connection, scope, command_id)
        if resolution:
            result.update(resolution=resolution["receipt"], eligible=False)
        return result

    def read(self, session_id, command_id, query):
        contract.exact(query, SCOPE if command_id is not None else SCOPE + (" after" if "after" in query else ""))
        if command_id is not None:
            sharing.identifier(command_id)
        after = sharing.identifier(query["after"]) if "after" in query else ""
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            initialize_schema(connection)
            actor, scope = self.source.scope(connection, session_id, query)
            if command_id is not None:
                result = self.detail(connection, session_id, scope, command_id, query)
                self.shares.audit(actor["email"], "review-field-edit", "staff-command", command_id, connection=connection)
                return result
            rows = connection.execute("""SELECT c.command_id FROM staff_workspace_commands c
                JOIN staff_workspace_selections s ON s.id=c.selection_id AND s.share_id=c.share_id
                LEFT JOIN staff_owner_field_edit_applications a ON a.command_id=c.command_id
                WHERE s.company_id=? AND s.environment=? AND s.replica_id=? AND c.command_id>?
                ORDER BY c.command_id LIMIT 51""", (*scope[:3], after)).fetchall()
            ids = []
            for row in rows[:50]:
                application = self.application(connection, row["command_id"])
                resolution = self.resolution(connection, scope, row["command_id"])
                if not resolution and (not application or application["receipt"]["state"] != "published"):
                    ids.append(row["command_id"])
            return dict(schema=SCHEMA, companyID=scope[0], environment=scope[1], replicaID=scope[2],
                        commandIDs=ids, nextCursor=rows[49]["command_id"] if len(rows) > 50 else None)

    def change(self, session_id, command_id, action, payload):
        if action not in ("prepare", "confirm"):
            raise contract.invalid()
        contract.exact(payload, PREPARE if action == "prepare" else CONFIRM)
        if payload["schema"] != SCHEMA or payload["commandID"] != command_id:
            raise sharing.fail("invalid_request", "Use the original field edit identity.", 400)
        for key in ("commandID", "operationID", "ownerStoreID"):
            sharing.identifier(payload[key])
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            initialize_schema(connection)
            actor, scope = self.source.scope(connection, session_id, payload)
            if self.resolution(connection, scope, command_id):
                raise sharing.fail("edit_resolved", "This field edit was explicitly retained without replacing office data. Keep its original audit history.", 409)
            entry = self.detail(connection, session_id, scope, command_id, payload)
            existing = self.application(connection, command_id)
            if existing:
                receipt = existing["receipt"]
                if receipt["ownerEmail"] != actor["email"] or any(receipt[k] != payload[k] for k in ("operationID", "ownerStoreID")):
                    raise sharing.fail("edit_claimed", "Recover this field edit on its original office device and business account.", 409)
                if action == "prepare" and contract.canonical(existing["request"]) != contract.canonical(payload):
                    raise sharing.fail("edit_changed", "Keep the original field-edit application request unchanged.", 409)
                if receipt["state"] == "published":
                    return receipt
            if action == "prepare" and not entry["eligible"]:
                raise sharing.fail("sharing_changed", "The original staff authority changed. Retain this edit for review.", 403)
            current = entry["current"]
            if current is None or current["deleted"]:
                raise sharing.fail("field_changed", "This office record was removed. Retain the field edit for review.", 409)
            if action == "prepare":
                contract.integer(payload["expectedRevision"], 1)
                if type(payload["reviewedConflict"]) is not bool:
                    raise contract.invalid()
                commands.validate_value(entry["request"]["recordKind"], entry["request"]["fieldName"], payload["expectedValue"])
                if existing:
                    if current["value"] not in (existing["receipt"]["expectedValue"], entry["request"]["value"]):
                        raise sharing.fail("field_changed", "Office data changed after preparation. Keep the original claim for review.", 409)
                    return existing["receipt"]
                if (payload["expectedRevision"] != current["revision"] or payload["expectedValue"] != current["value"] or
                        not payload["reviewedConflict"] and payload["expectedValue"] != entry["baseValue"]):
                    raise sharing.fail("field_changed", "Office data changed. Review the original field edit against the current saved value.", 409)
                if connection.execute("SELECT 1 FROM staff_owner_field_edit_applications WHERE operation_id=?", (payload["operationID"],)).fetchone():
                    raise sharing.fail("edit_claimed", "This operation belongs to another original field edit. Retain both originals for review.", 409)
                receipt = dict(schema=SCHEMA, commandID=command_id, operationID=payload["operationID"],
                    ownerStoreID=payload["ownerStoreID"], ownerEmail=actor["email"], preparedAt=self.shares.now().isoformat(),
                    expectedRevision=current["revision"], expectedValue=copy.deepcopy(current["value"]),
                    reviewedConflict=payload["reviewedConflict"], state="prepared", publishedAt=None)
                if self.valid_instant(receipt["preparedAt"]) < self.valid_instant(entry["receipt"]["createdAt"]):
                    raise self.source.unavailable()
                connection.execute("INSERT INTO staff_owner_field_edit_applications VALUES (?,?,?,?,?,?)",
                    (command_id, payload["operationID"], actor["email"], payload["ownerStoreID"], "prepared",
                     self.source.encode(dict(request=payload, receipt=receipt))))
            else:
                if not existing:
                    raise sharing.fail("edit_not_prepared", "Prepare the original field edit before confirming publication.", 409)
                if current["value"] != entry["request"]["value"] or current["revision"] < existing["receipt"]["expectedRevision"]:
                    raise sharing.fail("edit_not_published", "The saved field value has not reached the company source. Keep the original application for recovery.", 409)
                receipt = dict(existing["receipt"], state="published", publishedAt=self.shares.now().isoformat())
                if self.valid_instant(receipt["publishedAt"]) < self.valid_instant(receipt["preparedAt"]):
                    raise self.source.unavailable()
                connection.execute("UPDATE staff_owner_field_edit_applications SET state='published',ciphertext=? WHERE command_id=?",
                    (self.source.encode(dict(request=existing["request"], receipt=receipt)), command_id))
            self.shares.audit(actor["email"], action + "-field-edit", "staff-command", command_id, connection=connection)
            return receipt
