"""Same-owner recovery of an already published value; never transfers a claim."""
import copy

try:
    from Backend import staff_workspace_commands as commands
except ModuleNotFoundError:
    import staff_workspace_commands as commands

contract, sharing = commands.contract, commands.sharing
SCHEMA = "staff-owner-field-observation-v1"
FIELDS = commands.delivery.SCOPE_FIELDS + " schema commandID operationID observerStoreID claimOperationID expectedRevision expectedValue"


def initialize_schema(connection):
    connection.execute("""CREATE TABLE IF NOT EXISTS staff_owner_field_observations (
        operation_id TEXT PRIMARY KEY, command_id TEXT NOT NULL,
        observer_email TEXT NOT NULL, observer_store_id TEXT NOT NULL, ciphertext TEXT NOT NULL
    )""")


class StaffOwnerFieldObservations:
    def observation_request(self, connection, scope, command_id, payload):
        contract.exact(payload, FIELDS)
        if (payload["schema"] != SCHEMA or payload["commandID"] != command_id or
                tuple(payload[key] for key in ("companyID", "environment", "replicaID")) != scope[:3]):
            raise contract.invalid()
        for key in ("commandID", "operationID", "observerStoreID", "claimOperationID"):
            sharing.identifier(payload[key])
        contract.integer(payload["expectedRevision"], 1)
        _, original = self.command(connection, scope, command_id)
        commands.validate_value(original["request"]["recordKind"], original["request"]["fieldName"], payload["expectedValue"])
        if payload["expectedValue"] != original["request"]["value"]:
            raise sharing.fail("field_not_observed", "Verify the original field update in company records before confirming it.", 409)
        return original

    def observation(self, connection, scope, command_id, operation_id):
        row = connection.execute("SELECT * FROM staff_owner_field_observations WHERE operation_id=?", (operation_id,)).fetchone()
        if row is None:
            return None
        if row["command_id"] != command_id:
            raise sharing.fail("observation_changed", "Retain the original confirmation identity.", 409)
        try:
            receipt = self.source.decode(row["ciphertext"])
            contract.exact(receipt, "schema request ownerEmail observedAt application")
            request = receipt["request"]
            self.observation_request(connection, scope, command_id, request)
            self.valid_owner_email(receipt["ownerEmail"])
            application = self.application(connection, command_id)
            claim = application["receipt"] if application else None
            if (receipt["schema"] != SCHEMA or request["operationID"] != row["operation_id"] or
                    request["observerStoreID"] != row["observer_store_id"] or receipt["ownerEmail"] != row["observer_email"] or
                    claim is None or claim["state"] != "published" or receipt["application"] != claim or
                    claim["operationID"] != request["claimOperationID"] or claim["ownerEmail"] != receipt["ownerEmail"] or
                    claim["ownerStoreID"] == request["observerStoreID"] or request["expectedRevision"] < claim["expectedRevision"] or
                    self.valid_instant(receipt["observedAt"]) < self.valid_instant(claim["publishedAt"])):
                raise ValueError()
        except (sharing.AttemptError, ValueError, TypeError, KeyError):
            raise self.source.unavailable() from None
        return receipt

    def confirm_observed(self, session_id, command_id, payload):
        contract.exact(payload, FIELDS)
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            initialize_schema(connection)
            actor, scope = self.source.scope(connection, session_id, payload)
            self.observation_request(connection, scope, command_id, payload)
            existing = self.observation(connection, scope, command_id, payload["operationID"])
            if existing:
                if existing["ownerEmail"] != actor["email"] or existing["request"] != payload:
                    raise sharing.fail("observation_changed", "Retry the original confirmation unchanged.", 409)
                return existing
            if self.resolution(connection, scope, command_id):
                raise sharing.fail("edit_resolved", "This update was retained without replacing office data.", 409)
            entry = self.detail(connection, session_id, scope, command_id, payload)
            application = self.application(connection, command_id)
            claim = application["receipt"] if application else None
            if (claim is None or claim["operationID"] != payload["claimOperationID"] or
                    claim["ownerEmail"] != actor["email"] or claim["ownerStoreID"] == payload["observerStoreID"]):
                raise sharing.fail("edit_claimed", "Use the same owner account on another authorized office device to confirm an existing publication.", 409)
            current = entry["current"]
            if (current is None or current["deleted"] or current["revision"] != payload["expectedRevision"] or
                    current["value"] != payload["expectedValue"] or current["revision"] < claim["expectedRevision"]):
                raise sharing.fail("field_changed", "The reviewed source field changed. Verify it again without applying another edit.", 409)
            now = self.shares.now().isoformat()
            if self.valid_instant(now) < self.valid_instant(claim["preparedAt"]):
                raise self.source.unavailable()
            if claim["state"] == "prepared":
                claim = dict(claim, state="published", publishedAt=now)
            receipt = dict(schema=SCHEMA, request=copy.deepcopy(payload), ownerEmail=actor["email"], observedAt=now,
                           application=copy.deepcopy(claim))
            if self.valid_instant(now) < self.valid_instant(claim["publishedAt"]):
                raise self.source.unavailable()
            # Encrypt both records before changing either durable state.
            application_bytes = self.source.encode(dict(request=application["request"], receipt=claim))
            observation_bytes = self.source.encode(receipt)
            if application["receipt"]["state"] == "prepared":
                connection.execute("UPDATE staff_owner_field_edit_applications SET state='published',ciphertext=? WHERE command_id=?",
                                   (application_bytes, command_id))
            connection.execute("INSERT INTO staff_owner_field_observations VALUES (?,?,?,?,?)",
                (payload["operationID"], command_id, actor["email"], payload["observerStoreID"], observation_bytes))
            self.shares.audit(actor["email"], "observe-published-field-edit", "staff-command", command_id, connection=connection)
            return receipt
