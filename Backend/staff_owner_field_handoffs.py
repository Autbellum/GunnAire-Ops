"""Cooperative claim release after the original native store durably fences writes.

This is not a lease timeout or an absent-device takeover. Originals and released
claims are encrypted, append-only evidence; the released store cannot reclaim.
"""
import copy

try:
    from Backend import staff_workspace_commands as commands
except ModuleNotFoundError:
    import staff_workspace_commands as commands

contract, sharing = commands.contract, commands.sharing
SCHEMA = "staff-owner-field-handoff-v1"
FIELDS = commands.delivery.SCOPE_FIELDS + " schema commandID operationID ownerStoreID claimOperationID expectedRevision expectedValue writeFence"


def initialize_schema(connection):
    connection.execute("""CREATE TABLE IF NOT EXISTS staff_owner_field_handoffs (
        operation_id TEXT PRIMARY KEY, command_id TEXT NOT NULL, claim_operation_id TEXT NOT NULL UNIQUE,
        owner_store_id TEXT NOT NULL, owner_email TEXT NOT NULL, ciphertext TEXT NOT NULL,
        UNIQUE(command_id,owner_store_id)
    )""")
    for action in ("UPDATE", "DELETE"):
        connection.execute("CREATE TRIGGER IF NOT EXISTS staff_owner_field_handoffs_no_" + action.lower() +
                           " BEFORE " + action + " ON staff_owner_field_handoffs BEGIN SELECT RAISE(ABORT, 'Retain original handoff evidence'); END")


class StaffOwnerFieldHandoffs:
    def handoff_request(self, connection, scope, command_id, payload):
        contract.exact(payload, FIELDS)
        if (payload["schema"] != SCHEMA or payload["commandID"] != command_id or
                payload["writeFence"] != "before-save-v1" or
                tuple(payload[key] for key in ("companyID", "environment", "replicaID")) != scope[:3]):
            raise contract.invalid()
        for key in ("commandID", "operationID", "ownerStoreID", "claimOperationID"):
            sharing.identifier(payload[key])
        if payload["operationID"] == payload["claimOperationID"]:
            raise contract.invalid()
        contract.integer(payload["expectedRevision"], 1)
        _, original = self.command(connection, scope, command_id)
        commands.validate_value(original["request"]["recordKind"], original["request"]["fieldName"], payload["expectedValue"])
        return original

    def handoff_original(self, connection, row):
        try:
            saved = self.source.decode(row["ciphertext"])
            contract.exact(saved, "receipt application")
            receipt, application = saved["receipt"], saved["application"]
            contract.exact(receipt, "schema request ownerEmail releasedAt outcome")
            request = receipt["request"]
            scope = tuple(request[key] for key in ("companyID", "environment", "replicaID"))
            self.handoff_request(connection, scope, row["command_id"], request)
            if (receipt["schema"] != SCHEMA or receipt["outcome"] != "released" or
                    request["operationID"] != row["operation_id"] or request["claimOperationID"] != row["claim_operation_id"] or
                    request["ownerStoreID"] != row["owner_store_id"] or receipt["ownerEmail"] != row["owner_email"]):
                raise ValueError()
            self.validate_application(connection, row["command_id"], application,
                dict(operation_id=row["claim_operation_id"], owner_store_id=row["owner_store_id"], owner_email=row["owner_email"], state="prepared"))
            claim = application["receipt"]
            if (request["expectedValue"] != claim["expectedValue"] or request["expectedRevision"] < claim["expectedRevision"] or
                    self.valid_instant(receipt["releasedAt"]) < self.valid_instant(claim["preparedAt"])):
                raise ValueError()
            return receipt
        except (sharing.AttemptError, KeyError, TypeError, ValueError):
            raise self.source.unavailable() from None

    def assert_store_not_released(self, connection, command_id, owner_store_id):
        rows = connection.execute("SELECT * FROM staff_owner_field_handoffs WHERE command_id=? ORDER BY operation_id LIMIT 33",
                                  (command_id,)).fetchall()
        if len(rows) > 32:
            raise self.source.unavailable()
        for row in rows:
            self.handoff_original(connection, row)  # Corrupt history cannot enable a new owner's claim.
        if any(row["owner_store_id"] == owner_store_id for row in rows):
            raise sharing.fail("edit_released", "This device released the edit. Continue on another approved owner device; keep the original handoff history.", 409)

    def release_claim(self, session_id, command_id, payload):
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            initialize_schema(connection)
            actor, scope = self.source.scope(connection, session_id, payload)
            self.handoff_request(connection, scope, command_id, payload)
            previous = connection.execute("SELECT * FROM staff_owner_field_handoffs WHERE operation_id=?", (payload["operationID"],)).fetchone()
            if previous:
                receipt = self.handoff_original(connection, previous)
                if receipt["ownerEmail"] != actor["email"] or contract.canonical(receipt["request"]) != contract.canonical(payload):
                    raise sharing.fail("edit_changed", "Retain the exact original handoff request.", 409)
                return receipt
            self.assert_store_not_released(connection, command_id, payload["ownerStoreID"])
            if (connection.execute("SELECT count(*) FROM staff_owner_field_handoffs WHERE command_id=?", (command_id,)).fetchone()[0] >= 32 or
                    connection.execute("SELECT 1 FROM staff_owner_field_edit_applications WHERE operation_id=?", (payload["operationID"],)).fetchone()):
                raise sharing.fail("edit_claimed", "Retain the original handoff identities and review this edit's handoff history.", 409)
            entry = self.detail(connection, session_id, scope, command_id, payload)
            existing = self.application(connection, command_id)
            if entry.get("resolution") or not existing:
                raise sharing.fail("edit_not_prepared", "Only an original prepared edit can be released.", 409)
            claim = existing["receipt"]
            if (claim["state"] != "prepared" or claim["ownerEmail"] != actor["email"] or
                    claim["ownerStoreID"] != payload["ownerStoreID"] or claim["operationID"] != payload["claimOperationID"]):
                raise sharing.fail("edit_claimed", "Release this edit only on the original owner device and account.", 409)
            current = entry["current"]
            if (not current or current["deleted"] or current["revision"] != payload["expectedRevision"] or
                    current["revision"] < claim["expectedRevision"] or current["value"] != payload["expectedValue"] or
                    current["value"] != claim["expectedValue"] or current["value"] == entry["request"]["value"]):
                raise sharing.fail("field_changed", "The office value changed or already contains this update. Keep the original claim for recovery.", 409)
            receipt = dict(schema=SCHEMA, request=copy.deepcopy(payload), ownerEmail=actor["email"],
                           releasedAt=self.shares.now().isoformat(), outcome="released")
            if self.valid_instant(receipt["releasedAt"]) < self.valid_instant(claim["preparedAt"]):
                raise self.source.unavailable()
            sealed = self.source.encode(dict(receipt=receipt, application=existing))
            connection.execute("INSERT INTO staff_owner_field_handoffs VALUES (?,?,?,?,?,?)",
                (payload["operationID"], command_id, payload["claimOperationID"], payload["ownerStoreID"], actor["email"], sealed))
            # Move the active slot only after its full original is archived in
            # the same transaction. No command, local data or history is deleted.
            connection.execute("DELETE FROM staff_owner_field_edit_applications WHERE command_id=? AND operation_id=?",
                               (command_id, payload["claimOperationID"]))
            self.shares.audit(actor["email"], "release-field-edit", "staff-command", command_id, connection=connection)
            return receipt
