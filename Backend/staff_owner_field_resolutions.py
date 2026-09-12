"""Explicit keep-office decisions; never edits office data or deletes staff evidence."""
import copy

try:
    from Backend import staff_workspace_commands as commands
except ModuleNotFoundError:
    import staff_workspace_commands as commands

contract, sharing = commands.contract, commands.sharing
SCHEMA = "staff-owner-field-resolution-v1"
FIELDS = commands.delivery.SCOPE_FIELDS + " schema commandID operationID ownerStoreID claimOperationID expectedRevision expectedValue"


def initialize_schema(connection):
    connection.execute("""CREATE TABLE IF NOT EXISTS staff_owner_field_resolutions (
        command_id TEXT PRIMARY KEY, operation_id TEXT NOT NULL UNIQUE,
        owner_email TEXT NOT NULL, owner_store_id TEXT NOT NULL, ciphertext TEXT NOT NULL
    )""")


class StaffOwnerFieldResolutions:
    def resolution_request(self, connection, scope, command_id, payload):
        contract.exact(payload, FIELDS)
        if payload["schema"] != SCHEMA or payload["commandID"] != command_id:
            raise contract.invalid()
        for key in ("commandID", "operationID", "ownerStoreID"):
            sharing.identifier(payload[key])
        if payload["claimOperationID"] != "":
            sharing.identifier(payload["claimOperationID"])
        contract.integer(payload["expectedRevision"], 1)
        if tuple(payload[key] for key in ("companyID", "environment", "replicaID")) != scope[:3]:
            raise contract.invalid()
        _, original = self.command(connection, scope, command_id)
        commands.validate_value(original["request"]["recordKind"], original["request"]["fieldName"], payload["expectedValue"])
        return original

    def resolution(self, connection, scope, command_id):
        row = connection.execute("""SELECT r.* FROM staff_owner_field_resolutions r
            JOIN staff_workspace_commands c ON c.command_id=r.command_id
            JOIN staff_workspace_selections s ON s.id=c.selection_id AND s.share_id=c.share_id
            WHERE r.command_id=? AND s.company_id=? AND s.environment=? AND s.replica_id=?""",
            (command_id, *scope[:3])).fetchone()
        if row is None:
            return None
        try:
            saved = self.source.decode(row["ciphertext"])
            contract.exact(saved, "request receipt")
            request, receipt = saved["request"], saved["receipt"]
            original = self.resolution_request(connection, scope, command_id, request)
            contract.exact(receipt, "schema request ownerEmail resolvedAt outcome")
            if (receipt["schema"] != SCHEMA or receipt["outcome"] != "keptOffice" or
                    contract.canonical(receipt["request"]) != contract.canonical(request) or
                    receipt["ownerEmail"] != row["owner_email"] or request["ownerStoreID"] != row["owner_store_id"] or
                    request["operationID"] != row["operation_id"]):
                raise ValueError()
            resolved = self.valid_instant(receipt["resolvedAt"])
            if resolved < self.valid_instant(original["receipt"]["createdAt"]):
                raise ValueError()
            self.valid_owner_email(receipt["ownerEmail"])
            application = self.application(connection, command_id)
            claim = application["receipt"] if application else None
            if claim and resolved < self.valid_instant(claim["preparedAt"]):
                raise ValueError()
            if (request["claimOperationID"] != (claim["operationID"] if claim else "") or
                    claim and (claim["state"] != "prepared" or claim["ownerEmail"] != receipt["ownerEmail"] or claim["ownerStoreID"] != request["ownerStoreID"])):
                raise ValueError()
        except (sharing.AttemptError, ValueError, TypeError, KeyError):
            raise self.source.unavailable() from None
        return saved

    def keep_office(self, session_id, command_id, payload):
        contract.exact(payload, FIELDS)
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            initialize_schema(connection)
            actor, scope = self.source.scope(connection, session_id, payload)
            original = self.resolution_request(connection, scope, command_id, payload)
            self.assert_store_not_released(connection, command_id, payload["ownerStoreID"])
            existing = self.resolution(connection, scope, command_id)
            if existing:
                if (existing["receipt"]["ownerEmail"] != actor["email"] or
                        contract.canonical(existing["request"]) != contract.canonical(payload)):
                    raise sharing.fail("edit_resolved", "Recover the original keep-office decision without changing it.", 409)
                return existing["receipt"]
            entry = self.detail(connection, session_id, scope, command_id, payload)
            claim = entry["application"]
            if claim and claim["state"] == "published":
                raise sharing.fail("edit_published", "This field edit was already applied and published. Review the current office record instead.", 409)
            if (payload["claimOperationID"] != (claim["operationID"] if claim else "") or
                    claim and (claim["ownerEmail"] != actor["email"] or claim["ownerStoreID"] != payload["ownerStoreID"])):
                raise sharing.fail("edit_claimed", "Resolve a prepared edit on its original office device and business account.", 409)
            current = entry["current"]
            if (current is None or current["deleted"] or current["revision"] != payload["expectedRevision"] or
                    current["value"] != payload["expectedValue"]):
                raise sharing.fail("field_changed", "The saved office value changed. Review it again before keeping it.", 409)
            if connection.execute("SELECT 1 FROM staff_owner_field_resolutions WHERE operation_id=?", (payload["operationID"],)).fetchone():
                raise sharing.fail("edit_resolved", "This decision identity belongs to another original field edit.", 409)
            now = self.shares.now()
            if now < self.valid_instant(original["receipt"]["createdAt"]) or claim and now < self.valid_instant(claim["preparedAt"]):
                raise self.source.unavailable()
            receipt = dict(schema=SCHEMA, request=copy.deepcopy(payload), ownerEmail=actor["email"],
                           resolvedAt=now.isoformat(), outcome="keptOffice")
            connection.execute("INSERT INTO staff_owner_field_resolutions VALUES (?,?,?,?,?)", (command_id,
                payload["operationID"], actor["email"], payload["ownerStoreID"], self.source.encode(dict(request=payload, receipt=receipt))))
            self.shares.audit(actor["email"], "keep-office-field", "staff-command", command_id, connection=connection)
            return receipt
