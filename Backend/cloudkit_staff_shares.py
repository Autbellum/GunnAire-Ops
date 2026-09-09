"""Business authorization for separate-account, invite-only CloudKit replicas.

This registry is NOT CloudKit identity attestation or permission enforcement.
The signed native client must independently verify Apple's current account,
owner, zone, share and read-only participant permission before accepting or
opening a separate replica. It must never use this registry to open the legacy
company private store. No CloudKit/accounting/network writes occur here.
"""
from __future__ import annotations

import hashlib
import json
import re
import uuid
from datetime import datetime, timezone
from cryptography.fernet import InvalidToken

try:
    from Backend.payment_attempts import AttemptError
except ModuleNotFoundError:
    from payment_attempts import AttemptError


CONTAINER = "iCloud.com.gunnaire.businesssuite"
POLICIES = {
    "Admin": "admin-operations-v1",
    "Dispatcher": "dispatch-operations-v1",
    "Field Technician": "field-assigned-jobs-v1",
    "Accounting": "accounting-operations-v1",
    "Standard": "standard-self-v1",
}
SCHEMA = """
CREATE TABLE IF NOT EXISTS cloudkit_staff_shares (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, environment TEXT NOT NULL,
 replica_id TEXT NOT NULL, owner_account_hash TEXT NOT NULL,
 member_email TEXT NOT NULL, member_role TEXT NOT NULL, member_revision TEXT NOT NULL,
 participant_account_hash TEXT NOT NULL, projection_policy TEXT NOT NULL,
 zone_name TEXT NOT NULL UNIQUE, root_record_name TEXT NOT NULL, share_record_name TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('requested','approved','invited','accepted','revoked')),
 revision INTEGER NOT NULL CHECK(revision > 0),
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 approved_by TEXT, approver_revision TEXT, revoked_at TEXT,
 cloudkit_cleanup_required INTEGER NOT NULL DEFAULT 0 CHECK(cloudkit_cleanup_required IN (0,1))
);
CREATE UNIQUE INDEX IF NOT EXISTS cloudkit_staff_current ON cloudkit_staff_shares
 (company_id,environment,member_email) WHERE state != 'revoked';
CREATE INDEX IF NOT EXISTS cloudkit_staff_member ON cloudkit_staff_shares
 (company_id,environment,member_email,id);
CREATE TABLE IF NOT EXISTS cloudkit_staff_share_operations (
 operation_id TEXT PRIMARY KEY, share_id TEXT NOT NULL, actor_email TEXT NOT NULL,
 action TEXT NOT NULL, request_hash TEXT NOT NULL
);
"""


def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)
    columns = {row["name"] for row in connection.execute("PRAGMA table_info(cloudkit_staff_shares)")}
    if "participant_identity_ciphertext" not in columns:
        connection.execute("ALTER TABLE cloudkit_staff_shares ADD COLUMN participant_identity_ciphertext TEXT")


def fail(code, message, status=409):
    return AttemptError(code, message, status)


def identifier(value):
    try:
        if isinstance(value, str) and str(uuid.UUID(value)) == value:
            return value
    except ValueError:
        pass
    raise fail("invalid_request", "Use the original company and sharing request identifiers.", 400)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def account_hash(value):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise fail("invalid_request", "Verify the current iCloud account on this device.", 400)
    return value


def record_name(value, environment, expected_hash):
    if (not isinstance(value, str) or not 1 <= len(value.encode("utf-8")) <= 255
            or any(ord(c) < 32 or ord(c) == 127 for c in value)
            or hashlib.sha256(("gunnaire-cloudkit-account-v1\n" + CONTAINER + "\n" + environment + "\n" + value).encode()).hexdigest() != expected_hash):
        raise fail("account_changed", "Verify the exact current iCloud account before requesting access.", 400)
    return value


def scope(payload):
    company = identifier(payload.get("companyID"))
    environment = payload.get("environment")
    if environment not in ("development", "production"):
        raise fail("invalid_request", "Verify the signed CloudKit environment.", 400)
    return company, environment


def user_revision(user):
    return digest(["cloudkit-staff-user-v1", user["email"], user["role"], user["is_active"], user["updated_at"]])


class StaffShares:
    def __init__(self, database, audit, now=None, *, encrypt=None, decrypt=None):
        self.database, self.audit = database, audit
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.encrypt, self.decrypt = encrypt, decrypt

    def participant_identity(self, row):
        if not row["participant_identity_ciphertext"]:
            raise fail("identity_required", "Ask this team member to withdraw the old request and request access again from their iCloud account.")
        try:
            decoded = json.loads(self.decrypt(row["participant_identity_ciphertext"]))
            if (not isinstance(decoded, dict) or set(decoded) != {"id", "companyID", "environment", "accountHash", "recordName"}
                    or decoded["id"] != row["id"] or decoded["companyID"] != row["company_id"]
                    or decoded["environment"] != row["environment"] or decoded["accountHash"] != row["participant_account_hash"]):
                raise ValueError()
            return record_name(decoded["recordName"], row["environment"], row["participant_account_hash"])
        except (ValueError, TypeError, AttemptError, RuntimeError, InvalidToken):
            raise fail("storage_unavailable", "The original iCloud invitation identity could not be verified. Keep the request for review.", 503) from None

    def lookup_participant(self, session_id, share_id, payload):
        if not isinstance(payload, dict) or set(payload) != {"companyID", "environment"}:
            raise fail("invalid_query", "Choose the original invitation identity.", 400)
        company, environment = scope(payload)
        identifier(share_id)
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor = self.actor(connection, session_id, administrator=True)
            row = connection.execute("SELECT * FROM cloudkit_staff_shares WHERE id=?", (share_id,)).fetchone()
            self.authorize_row(connection, actor, row, company, environment)
            member_valid, approver_valid = self.eligibility(connection, row)
            if row["state"] == "revoked" or not member_valid or (row["state"] != "requested" and not approver_valid):
                raise fail("review_changed", "Review the current business authority before looking up this invitation.")
            name = self.participant_identity(row)
            self.audit(actor["email"], "read-identity", "cloudkit-staff-share", share_id, connection=connection)
            return {"id": row["id"], "companyID": company, "environment": environment, "revision": row["revision"],
                    "participantAccountHash": row["participant_account_hash"], "recordName": name}

    def actor(self, connection, session_id, *, administrator=False):
        actor = connection.execute(
            """SELECT s.*,u.role,u.is_active,u.updated_at AS user_updated_at FROM auth_sessions s
               JOIN users u ON u.email=s.email WHERE s.id=?""", (session_id,),
        ).fetchone()
        now = self.now()
        try:
            issued = datetime.fromisoformat(actor["created_at"].replace("Z", "+00:00"))
            expires = datetime.fromisoformat(actor["expires_at"].replace("Z", "+00:00"))
            valid = (actor["revoked_at"] is None and actor["is_active"] == 1 and actor["role"] in POLICIES
                     and issued.tzinfo is not None and expires.tzinfo is not None and issued <= now < expires)
            if administrator:
                valid = valid and actor["role"] == "Admin" and (now - issued).total_seconds() <= 600
        except (TypeError, ValueError):
            valid = False
        if not valid:
            raise fail("access_required", "Sign in again with current administrator access." if administrator else
                       "Current approved business sign-in is required.", 403)
        return actor

    def binding(self, connection, company, environment):
        identity = connection.execute("SELECT company_id FROM company_identity WHERE singleton=1").fetchone()
        if identity is None:
            raise fail("storage_unavailable", "Restore the original company identity before sharing.", 503)
        if identity[0] != company:
            raise fail("company_changed", "Reopen the original business workspace.", 403)
        binding = connection.execute(
            "SELECT * FROM cloudkit_workspace_bindings WHERE container_id=? AND environment=?", (CONTAINER, environment),
        ).fetchone()
        if binding is None:
            raise fail("owner_required", "Approve the company-owned CloudKit workspace before inviting staff.")
        identifier(binding["replica_id"])
        account_hash(binding["cloud_account_hash"])
        return binding

    def authorize_row(self, connection, actor, row, company, environment):
        # Do not reveal whether another employee's request exists.
        if (row is None or row["company_id"] != company or row["environment"] != environment
                or (actor["role"] != "Admin" and row["member_email"] != actor["email"])):
            raise fail("not_found", "This sharing request is not available to this business account.", 404)
        binding = self.binding(connection, company, environment)
        if row["replica_id"] != binding["replica_id"] or row["owner_account_hash"] != binding["cloud_account_hash"]:
            raise fail("workspace_changed", "The original company CloudKit binding changed. Review recovery before sharing.")

    def eligibility(self, connection, row):
        member = connection.execute("SELECT * FROM users WHERE email=?", (row["member_email"],)).fetchone()
        member_valid = (member is not None and member["is_active"] == 1
                        and member["role"] == row["member_role"] and user_revision(member) == row["member_revision"])
        approver = connection.execute("SELECT * FROM users WHERE email=?", (row["approved_by"],)).fetchone()
        approver_valid = (approver is not None and approver["is_active"] == 1 and approver["role"] == "Admin"
                          and user_revision(approver) == row["approver_revision"])
        return bool(member_valid), bool(approver_valid)

    def public(self, connection, row):
        member_valid, approver_valid = self.eligibility(connection, row)
        eligible = member_valid and approver_valid and row["state"] == "accepted"
        return {
            "protocolVersion": 1, "id": row["id"], "companyID": row["company_id"], "containerID": CONTAINER,
            "environment": row["environment"], "replicaID": row["replica_id"],
            "ownerAccountHash": row["owner_account_hash"], "participantAccountHash": row["participant_account_hash"],
            "memberEmail": row["member_email"], "memberRole": row["member_role"],
            "memberRevision": row["member_revision"], "projectionPolicy": row["projection_policy"],
            "zoneName": row["zone_name"], "rootRecordName": row["root_record_name"], "shareRecordName": row["share_record_name"],
            "state": row["state"], "revision": row["revision"], "createdAt": row["created_at"], "updatedAt": row["updated_at"],
            "participantIdentityAvailable": bool(row["participant_identity_ciphertext"]),
            "businessAccessEligible": eligible, "localCloudKitProofRequired": True,
            "reviewRequired": not member_valid or (row["state"] not in ("requested", "revoked") and not approver_valid),
            # Role changes revoke business eligibility but do not erase Apple's
            # independent permissions. Owner cleanup must be visible, not implied.
            "cloudKitRevocationRequired": bool(row["cloudkit_cleanup_required"] or
                (row["state"] in ("approved", "invited", "accepted") and not (member_valid and approver_valid))),
        }

    def enroll(self, session_id, payload):
        fields = {"companyID", "environment", "operationID", "participantAccountHash"}
        if not isinstance(payload, dict) or set(payload) not in (fields, fields | {"participantRecordName"}):
            raise fail("invalid_request", "Use only the current account and original sharing request fields.", 400)
        company, environment = scope(payload)
        operation, participant = identifier(payload["operationID"]), account_hash(payload["participantAccountHash"])
        name = record_name(payload["participantRecordName"], environment, participant) if "participantRecordName" in payload else None
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor = self.actor(connection, session_id)
            binding = self.binding(connection, company, environment)
            if participant == binding["cloud_account_hash"]:
                raise fail("owner_device", "Use existing company-device verification for the approved business iCloud account.")
            old = connection.execute("SELECT * FROM cloudkit_staff_shares WHERE id=?", (operation,)).fetchone()
            user = connection.execute("SELECT * FROM users WHERE email=?", (actor["email"],)).fetchone()
            revision = user_revision(user)
            if old is not None:
                self.authorize_row(connection, actor, old, company, environment)
                if old["member_email"] != actor["email"] or old["participant_account_hash"] != participant:
                    raise fail("operation_changed", "Recover the original request without changing its account.")
                if (name is None) != (old["participant_identity_ciphertext"] is None) or (name is not None and self.participant_identity(old) != name):
                    raise fail("operation_changed", "Recover the original account request without replacing its identity.")
                # A late retry returns current state; never reactivates revoked
                # membership or changes the original reviewed role/account.
                return self.public(connection, old)
            if connection.execute("SELECT 1 FROM cloudkit_staff_share_operations WHERE operation_id=?", (operation,)).fetchone():
                raise fail("operation_changed", "Keep a distinct operation identifier for this enrollment.")
            if connection.execute(
                "SELECT 1 FROM cloudkit_staff_shares WHERE company_id=? AND environment=? AND member_email=? AND state!='revoked'",
                (company, environment, actor["email"]),
            ).fetchone():
                raise fail("request_exists", "Recover the existing sharing request. Review revocation before changing iCloud accounts.")
            now = self.now().isoformat()
            ciphertext = None
            if name is not None:
                if self.encrypt is None:
                    raise fail("storage_unavailable", "Secure invitation identity storage is not configured.", 503)
                ciphertext = self.encrypt(json.dumps({"id": operation, "companyID": company, "environment": environment,
                                                     "accountHash": participant, "recordName": name}, separators=(",", ":")))
            connection.execute(
                """INSERT INTO cloudkit_staff_shares (id,company_id,environment,replica_id,owner_account_hash,
                   member_email,member_role,member_revision,participant_account_hash,projection_policy,
                   zone_name,root_record_name,share_record_name,state,revision,created_at,updated_at,participant_identity_ciphertext)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'requested',1,?,?,?)""",
                (operation, company, environment, binding["replica_id"], binding["cloud_account_hash"],
                 actor["email"], actor["role"], revision, participant, POLICIES[actor["role"]],
                 "ga-staff-" + str(uuid.uuid4()), "workspace", "share-" + str(uuid.uuid4()), now, now, ciphertext),
            )
            self.audit(actor["email"], "request", "cloudkit-staff-share", operation, connection=connection)
            return self.public(connection, connection.execute("SELECT * FROM cloudkit_staff_shares WHERE id=?", (operation,)).fetchone())

    def read(self, session_id, payload, share_id=None, *, administrator=False):
        required = {"companyID", "environment"}
        if not isinstance(payload, dict) or set(payload) not in (required, required | {"after"}):
            raise fail("invalid_query", "Choose the original company and CloudKit environment.", 400)
        company, environment = scope(payload)
        after = identifier(payload["after"]) if "after" in payload else ""
        if share_id is not None:
            identifier(share_id)
            if after:
                raise fail("invalid_query", "Read the original sharing request without a list cursor.", 400)
        with self.database() as connection:
            # One consistent authority/rows snapshot, including role changes.
            connection.execute("BEGIN")
            actor = self.actor(connection, session_id, administrator=administrator)
            self.binding(connection, company, environment)
            if share_id is not None:
                row = connection.execute("SELECT * FROM cloudkit_staff_shares WHERE id=?", (share_id,)).fetchone()
                self.authorize_row(connection, actor, row, company, environment)
                return self.public(connection, row)
            query = "SELECT * FROM cloudkit_staff_shares WHERE company_id=? AND environment=? AND id>?"
            arguments = [company, environment, after]
            if actor["role"] != "Admin":
                query += " AND member_email=?"
                arguments.append(actor["email"])
            rows = connection.execute(query + " ORDER BY id LIMIT 51", arguments).fetchall()
            for row in rows:
                self.authorize_row(connection, actor, row, company, environment)
            return {"shares": [self.public(connection, row) for row in rows[:50]],
                    "nextCursor": rows[49]["id"] if len(rows) > 50 else None}

    def change(self, session_id, share_id, action, payload):
        fields = {"companyID", "environment", "operationID", "expectedRevision"}
        confirmations = {
            "approve": "confirmRoleScopedReadOnlySharing",
            "invite": "confirmPrivateReadOnlyCloudKitShare",
            "accept": "confirmLocalCloudKitProof",
            "revoke": "confirmBusinessAccessRevocation",
            "confirm-cleanup": "confirmCloudKitAccessRemoved",
        }
        confirmation = confirmations.get(action)
        if confirmation is None:
            raise fail("not_found", "Sharing action not found.", 404)
        if action == "accept":
            fields.add("participantAccountHash")
        if (not isinstance(payload, dict) or set(payload) != fields | {confirmation}
                or payload[confirmation] is not True or type(payload.get("expectedRevision")) is not int
                or not 1 <= payload["expectedRevision"] < 2147483647):
            raise fail("invalid_request", "Review the original sharing request and explicitly confirm this action.", 400)
        company, environment = scope(payload)
        identifier(share_id)
        operation = identifier(payload["operationID"])
        request_hash = digest([share_id, action, payload])
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor = self.actor(connection, session_id)
            row = connection.execute("SELECT * FROM cloudkit_staff_shares WHERE id=?", (share_id,)).fetchone()
            self.authorize_row(connection, actor, row, company, environment)
            if action in ("approve", "invite", "confirm-cleanup") or (action == "revoke" and actor["email"] != row["member_email"]):
                actor = self.actor(connection, session_id, administrator=True)
            if action == "accept" and (actor["email"] != row["member_email"] or
                    account_hash(payload["participantAccountHash"]) != row["participant_account_hash"]):
                raise fail("participant_changed", "Only the original participant can confirm their current iCloud account.", 403)
            old = connection.execute("SELECT * FROM cloudkit_staff_share_operations WHERE operation_id=?", (operation,)).fetchone()
            if old is not None:
                if old["share_id"] != share_id or old["actor_email"] != actor["email"] or old["request_hash"] != request_hash:
                    raise fail("operation_changed", "Recover the original sharing action without replacing its values.")
                return self.public(connection, row)
            if connection.execute("SELECT 1 FROM cloudkit_staff_shares WHERE id=?", (operation,)).fetchone():
                raise fail("operation_changed", "Keep a distinct operation identifier for each sharing action.")
            if row["revision"] != payload["expectedRevision"]:
                raise fail("review_changed", "The sharing request changed. Refresh its original state before continuing.")
            member_valid, approver_valid = self.eligibility(connection, row)
            if action in ("approve", "invite", "accept") and not member_valid:
                raise fail("member_changed", "This team member's access changed. Revoke this request and review a new invitation.")
            if action in ("approve", "invite"):
                self.participant_identity(row)
            if action in ("invite", "accept") and not approver_valid:
                raise fail("approver_changed", "The original approving administrator's access changed. Review a new invitation.")
            expected = {"approve": "requested", "invite": "approved", "accept": "invited", "confirm-cleanup": "revoked"}
            if (action in expected and row["state"] != expected[action]) or (action == "revoke" and row["state"] == "revoked"):
                raise fail("state_changed", "Recover the original sharing action. This request has already changed.")
            state = {"approve": "approved", "invite": "invited", "accept": "accepted", "revoke": "revoked", "confirm-cleanup": "revoked"}[action]
            cleanup = row["cloudkit_cleanup_required"]
            if action == "revoke":
                cleanup = int(row["state"] != "requested")  # Includes a lost reply after owner share creation.
            if action == "confirm-cleanup":
                if not cleanup:
                    raise fail("cleanup_not_required", "No outstanding CloudKit cleanup exists for this request.")
                cleanup = 0
            approver, approver_revision = row["approved_by"], row["approver_revision"]
            if action == "approve":
                approver = actor["email"]
                approver_revision = user_revision(connection.execute("SELECT * FROM users WHERE email=?", (approver,)).fetchone())
            now = self.now().isoformat()
            connection.execute(
                """UPDATE cloudkit_staff_shares SET state=?,revision=revision+1,updated_at=?,approved_by=?,
                   approver_revision=?,revoked_at=?,cloudkit_cleanup_required=? WHERE id=?""",
                (state, now, approver, approver_revision, now if action == "revoke" else row["revoked_at"], cleanup, share_id),
            )
            connection.execute("INSERT INTO cloudkit_staff_share_operations VALUES (?,?,?,?,?)",
                               (operation, share_id, actor["email"], action, request_hash))
            self.audit(actor["email"], action, "cloudkit-staff-share", share_id, connection=connection)
            return self.public(connection, connection.execute("SELECT * FROM cloudkit_staff_shares WHERE id=?", (share_id,)).fetchone())
