"""Durable administrator-reviewed QBO catalog publication.

One dispatch per immutable intent. Uncertain sends are recovered by provider
reads, never automatically resent. This is not a general accounting proxy.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
import sqlite3
import uuid
from datetime import date, datetime, timezone

try:
    from Backend.payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference
except ModuleNotFoundError:
    from payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference

SCHEMA = """
CREATE TABLE IF NOT EXISTS catalog_publications (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, realm_id TEXT NOT NULL,
 environment TEXT NOT NULL, local_item_id TEXT NOT NULL, operation TEXT NOT NULL,
 payload_hash TEXT NOT NULL, payload_ciphertext TEXT NOT NULL,
 grant_fingerprint TEXT NOT NULL, request_id TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('reserved','sending','unknown','confirmed','cancelled')),
 provider_id TEXT, actor_email TEXT NOT NULL, created_at TEXT NOT NULL,
 updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS catalog_open_item ON catalog_publications
 (company_id,realm_id,environment,local_item_id)
 WHERE state IN ('reserved','sending','unknown');
CREATE TABLE IF NOT EXISTS catalog_entity_mappings (
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 local_item_id TEXT NOT NULL, provider_id TEXT NOT NULL,
 PRIMARY KEY(company_id,realm_id,environment,local_item_id),
 UNIQUE(company_id,realm_id,environment,provider_id)
);
CREATE TABLE IF NOT EXISTS catalog_publication_keys (
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 identity_hash TEXT NOT NULL, publication_id TEXT NOT NULL,
 PRIMARY KEY(company_id,realm_id,environment,identity_hash)
);
"""

def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)


def failure(code, message, status=409):
    return AttemptError(code, message, status)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def scope(row):
    return row["company_id"], row["realm_id"], row["environment"]


INVENTORY_CREATE_FIELDS = {"QtyOnHand", "InvStartDate", "TrackQtyOnHand", "AssetAccountRef"}


def inventory_fields(value, *, opening=False):
    """Validate inventory evidence without turning a read balance into an adjustment.

    Only an explicitly reviewed create carries an opening balance. Existing
    inventory can legitimately go negative after sales; reads must retain it.
    The quantity bound is this application's limit, not a claimed Intuit limit.
    """
    quantity = value.get("QtyOnHand")
    if (type(quantity) not in (int, float) or not math.isfinite(quantity)
            or not (-99999999999 <= quantity <= 99999999999)
            or (opening and quantity < 0) or value.get("TrackQtyOnHand") is not True):
        raise failure("inventory_review", "Review the inventory quantity and quantity-tracking setting.", 400 if opening else 409)
    start = value.get("InvStartDate")
    try:
        if not isinstance(start, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", start):
            raise ValueError()
        date.fromisoformat(start)
    except ValueError:
        raise failure("inventory_review", "Choose a valid inventory opening date.", 400 if opening else 409) from None
    for field in ("AssetAccountRef", "IncomeAccountRef", "ExpenseAccountRef"):
        account = value.get(field)
        if not isinstance(account, dict):
            raise failure("inventory_review", "Choose the inventory asset, product income and cost-of-goods-sold accounts.", 400 if opening else 409)
        reference(account.get("value"))


def validate_inventory_accounts(item, provider):
    """Read only the three explicit references in this original scoped proposal."""
    requirements = (
        ("AssetAccountRef", "Other Current Asset", "Inventory"),
        ("IncomeAccountRef", "Income", "SalesOfProductIncome"),
        ("ExpenseAccountRef", "Cost of Goods Sold", None),
    )
    for field, kind, subtype in requirements:
        identifier = item[field]["value"]
        account = provider.read("account", identifier)
        if (not isinstance(account, dict) or account.get("Id") != identifier
                or account.get("Active") is not True or account.get("AccountType") != kind
                or (subtype is not None and account.get("AccountSubType") != subtype)):
            raise failure("inventory_account_review", "Review the active inventory asset, product income and cost-of-goods-sold accounts in this QuickBooks company.")


def validate_item(item, operation):
    common = {"Name", "Description", "Sku", "PurchaseDesc", "UnitPrice", "PurchaseCost", "Taxable", "PrefVendorRef"}
    allowed = common | ({"Type", "IncomeAccountRef", "ExpenseAccountRef"} | INVENTORY_CREATE_FIELDS if operation == "create"
                        else {"Id", "SyncToken", "sparse", "Active", "Type"})
    required = {"Name"} | ({"Type", "IncomeAccountRef"} if operation == "create" else
                          {"Id", "SyncToken", "sparse", "Active", "Description", "Sku", "PurchaseDesc", "UnitPrice", "PurchaseCost", "Taxable"})
    if not isinstance(item, dict) or set(item) - allowed or not required <= set(item):
        raise failure("invalid_item", "Use the supported catalog item fields only.", 400)
    result = dict(item)
    for key, limit in (("Name", 100), ("Sku", 100), ("Description", 4000), ("PurchaseDesc", 1000)):
        if key not in item:
            continue
        value = item[key]
        if not isinstance(value, str) or len(value) > limit or "\x00" in value:
            raise failure("invalid_item", "Review the item name, SKU and description lengths.", 400)
    if not item["Name"].strip() or item["Name"] != item["Name"].strip() or any(x in item["Name"] for x in ":\t\r\n"):
        raise failure("invalid_item", "Use a nonempty item name without colons, tabs or new lines.", 400)
    for key in ("UnitPrice", "PurchaseCost"):
        if key in item and (type(item[key]) not in (int, float) or not math.isfinite(item[key]) or not 0 <= item[key] <= 99999999999):
            raise failure("invalid_item", "Enter a finite, nonnegative item price and cost within QuickBooks limits.", 400)
    for key in ("Taxable", "Active", "sparse"):
        if key in item and type(item[key]) is not bool:
            raise failure("invalid_item", "Use boolean catalog flags.", 400)
    for key in ("IncomeAccountRef", "ExpenseAccountRef", "AssetAccountRef", "PrefVendorRef"):
        if key in item:
            value = item[key]
            if not isinstance(value, dict) or set(value) - {"value", "name"} or "value" not in value:
                raise failure("invalid_item", "Choose a valid accounting reference.", 400)
            reference(value["value"])
            if "name" in value and (not isinstance(value["name"], str) or len(value["name"]) > 500):
                raise failure("invalid_item", "Choose a valid accounting reference.", 400)
            # Names are presentation metadata, never accounting identity.
            result[key] = {"value": value["value"]}
    if operation == "create":
        if item["Type"] not in ("Service", "NonInventory", "Inventory"):
            raise failure("invalid_item", "Publish service, non-inventory or inventory items through this workflow.", 400)
        if item["Type"] == "Inventory":
            inventory_fields(result, opening=True)
        elif INVENTORY_CREATE_FIELDS & set(item):
            raise failure("invalid_item", "Opening balances and inventory accounts belong only to inventory items.", 400)
    elif operation == "update":
        reference(item["Id"])
        reference(item["SyncToken"])
        # Type is review evidence, not permission to convert an item. Legacy
        # Service/NonInventory proposals remain readable without this field.
        if "Type" in item and item["Type"] not in ("Service", "NonInventory", "Inventory"):
            raise failure("invalid_item", "Review the original item type before updating it.", 400)
        if item["sparse"] is not True:
            raise failure("invalid_item", "Use reviewed sparse catalog updates.", 400)
    else:
        raise failure("invalid_operation", "Choose create or update.", 400)
    return result


def connection_pin(payload):
    if "connectionRevision" not in payload:
        return {}
    value = payload["connectionRevision"]
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise failure("invalid_request", "Review the original business connection.", 400)
    return {"connection_revision": value}


def validate_connection_pin(intent, fingerprint):
    # SQLite rows from older immutable attempts retain their internal grant
    # fingerprint. New preparations may additionally pin the public epoch.
    if "connection_revision" in intent.keys():
        expected = hashlib.sha256(canonical(["job-billing-connection-v1", fingerprint]).encode()).hexdigest()
        if intent["connection_revision"] != expected:
            raise failure("grant_changed", "The business connection changed. Review the original saved work.")


def validated_request(payload):
    required = {"companyID", "realmID", "environment", "localItemID", "operation", "item"}
    if not isinstance(payload, dict) or set(payload) not in (required, required | {"connectionRevision"}):
        raise failure("invalid_request", "Use the supported catalog publication fields only.", 400)
    if payload["environment"] not in ("sandbox", "production") or payload["operation"] not in ("create", "update"):
        raise failure("invalid_request", "Choose a valid catalog operation and environment.", 400)
    return {
        "company_id": canonical_uuid(payload["companyID"]), "realm_id": reference(payload["realmID"]),
        "environment": payload["environment"], "local_item_id": canonical_uuid(payload["localItemID"]),
        "operation": payload["operation"], "item": validate_item(payload["item"], payload["operation"]),
        **connection_pin(payload),
    }


def validated_remote(remote):
    if not isinstance(remote, dict):
        raise failure("provider_unconfirmed", "QuickBooks returned incomplete item evidence.")
    reference(remote.get("Id"))
    reference(remote.get("SyncToken"))
    if not isinstance(remote.get("Name"), str) or not remote["Name"].strip() or remote.get("Type") not in ("Service", "NonInventory", "Inventory"):
        raise failure("provider_unconfirmed", "QuickBooks returned incomplete item evidence.")
    if type(remote.get("Active")) is not bool:
        raise failure("provider_unconfirmed", "QuickBooks did not confirm whether this item is active.")
    for key in ("UnitPrice", "PurchaseCost"):
        value = remote.get(key, 0)
        if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 99999999999:
            raise failure("provider_unconfirmed", "QuickBooks returned invalid catalog amounts.")
    if remote["Type"] == "Inventory":
        inventory_fields(remote)
    return remote


def same_identity(item, remote):
    return (item["Name"].strip().casefold() == remote.get("Name", "").strip().casefold()
            and item.get("Sku", "").strip().casefold() == remote.get("Sku", "").strip().casefold()
            and item.get("Type", remote.get("Type")) == remote.get("Type"))


def same_values(item, remote):
    for key, value in item.items():
        if key in ("Id", "SyncToken", "sparse"):
            continue
        if key.endswith("Ref"):
            if not isinstance(remote.get(key), dict) or remote[key].get("value") != value["value"]:
                return False
        elif key in ("Description", "Sku", "PurchaseDesc"):
            if remote.get(key, "") != value:
                return False
        elif remote.get(key, 0 if key in ("UnitPrice", "PurchaseCost") else None) != value:
            return False
    return True


class CatalogPublisher:
    def __init__(self, database, provider_factory, encrypt, decrypt, audit, now=None):
        self.database, self.provider_factory = database, provider_factory
        self.encrypt, self.decrypt, self.audit = encrypt, decrypt, audit
        self.now = now or (lambda: datetime.now(timezone.utc))

    def authorize(self, connection, session_id, intent, require_grant=True):
        actor = connection.execute(
            """SELECT s.*,u.role,u.is_active FROM auth_sessions s JOIN users u ON u.email=s.email WHERE s.id=?""",
            (session_id,),
        ).fetchone()
        try:
            issued = datetime.fromisoformat(actor["created_at"].replace("Z", "+00:00"))
            expires = datetime.fromisoformat(actor["expires_at"].replace("Z", "+00:00"))
            valid = (actor["revoked_at"] is None and actor["is_active"] and actor["role"] == "Admin"
                     and issued.tzinfo is not None and expires.tzinfo is not None and issued <= self.now() < expires)
        except (TypeError, ValueError):
            valid = False
        if not valid:
            raise failure("administrator_required", "Sign in with current administrator access to publish the shared pricebook.", 403)
        company = connection.execute("SELECT company_id FROM company_identity WHERE singleton=1").fetchone()
        if company is None or company[0] != intent["company_id"]:
            raise failure("company_changed", "Reopen the original business workspace.", 403)
        grant = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
        if grant is None or grant["realm_id"] != intent["realm_id"] or grant["environment"] != intent["environment"]:
            raise failure("provider_changed", "Reconnect the original QuickBooks company before reviewing this item.")
        fingerprint = grant_fingerprint(grant)
        validate_connection_pin(intent, fingerprint)
        if require_grant and fingerprint != intent["grant_fingerprint"]:
            raise failure("grant_changed", "QuickBooks was reconnected. The original catalog attempt needs administrator review.")
        return actor, {**dict(grant), "grant_fingerprint": fingerprint}

    def record(self, connection, identifier):
        row = connection.execute("SELECT * FROM catalog_publications WHERE id=?", (canonical_uuid(identifier),)).fetchone()
        if row is None:
            raise failure("not_found", "Catalog publication not found.", 404)
        return row

    def public(self, row):
        return {key: row[column] for key, column in (
            ("id", "id"), ("companyID", "company_id"), ("realmID", "realm_id"), ("environment", "environment"),
            ("localItemID", "local_item_id"), ("operation", "operation"), ("state", "state"),
            ("providerID", "provider_id"), ("updatedAt", "updated_at"))}

    def reserve(self, session_id, payload):
        intent = validated_request(payload)
        # Authorization evidence is checked atomically below, then persisted
        # in grant_fingerprint. Keep the original business-payload hash format
        # so its encrypted item and older device retries remain verifiable.
        digest = hashlib.sha256(canonical({key: value for key, value in intent.items() if key != "connection_revision"}).encode()).hexdigest()
        # Encrypt before a reservation can become dispatchable.
        ciphertext = self.encrypt(canonical(intent["item"]))
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, grant = self.authorize(connection, session_id, intent, require_grant=False)
            rows = connection.execute(
                """SELECT * FROM catalog_publications WHERE company_id=? AND realm_id=? AND environment=?
                   AND local_item_id=? AND state!='cancelled' ORDER BY created_at DESC""",
                (*scope(intent), intent["local_item_id"]),
            ).fetchall()
            for row in rows:
                if row["payload_hash"] == digest:
                    self.authorize(connection, session_id, row)
                    return dict(row)
            if any(row["state"] in ("reserved", "sending", "unknown") for row in rows):
                raise failure("publication_pending", "An earlier version of this item is still pending. Review that attempt before publishing changes.")
            # A local UUID that was created once cannot create another provider ID.
            if intent["operation"] == "create" and rows:
                raise failure("already_published", "This item was already published. Recover its original link before reviewing changes.")
            identifier = str(uuid.uuid4())
            request_id = ("ga-item-" + intent["local_item_id"]) if intent["operation"] == "create" else ("ga-iu-" + digest[:44])
            now = self.now().isoformat()
            connection.execute(
                """INSERT INTO catalog_publications VALUES (?,?,?,?,?,?,?,?,?,?,'reserved',NULL,?,?,?)""",
                (identifier, *scope(intent), intent["local_item_id"], intent["operation"], digest, ciphertext,
                 grant["grant_fingerprint"], request_id, actor["email"], now, now),
            )
            keys = ["name:" + intent["item"]["Name"].casefold()]
            if intent["item"].get("Sku", "").strip():
                keys.append("sku:" + intent["item"]["Sku"].strip().casefold())
            if intent["operation"] == "update":
                keys.append("id:" + intent["item"]["Id"])
            try:
                for key in keys:
                    connection.execute("INSERT INTO catalog_publication_keys VALUES (?,?,?,?,?)",
                                       (*scope(intent), hashlib.sha256(key.encode()).hexdigest(), identifier))
            except sqlite3.IntegrityError:
                raise failure("catalog_busy", "Another item with this name, SKU or QuickBooks identity is being reviewed.") from None
            self.audit(actor["email"], "reserve", "catalog-publication", identifier, connection=connection)
            return dict(self.record(connection, identifier))

    def check(self, session_id, identifier):
        with self.database() as connection:
            row = self.record(connection, identifier)
            _, context = self.authorize(connection, session_id, row)
            if row["state"] == "cancelled":
                raise failure("cancelled", "This unsent catalog attempt was cancelled.")
            return dict(row), context

    def item_payload(self, row):
        raw = self.decrypt(row["payload_ciphertext"])
        if not raw:
            raise failure("storage_unavailable", "The original catalog proposal cannot be read. No new request was sent.", 503)
        try:
            item = validate_item(json.loads(raw), row["operation"])
        except (ValueError, TypeError, AttemptError):
            raise failure("storage_unavailable", "The original catalog proposal is unavailable.", 503) from None
        expected = {key: row[key] for key in ("company_id", "realm_id", "environment", "local_item_id", "operation")}
        expected["item"] = item
        if hashlib.sha256(canonical(expected).encode()).hexdigest() != row["payload_hash"]:
            raise failure("storage_unavailable", "The original catalog proposal failed its integrity check.", 503)
        return item

    def mapping(self, connection, row, provider_id):
        existing = connection.execute(
            """SELECT * FROM catalog_entity_mappings WHERE company_id=? AND realm_id=? AND environment=?
               AND (local_item_id=? OR provider_id=?)""", (*scope(row), row["local_item_id"], provider_id),
        ).fetchall()
        if any(value["local_item_id"] != row["local_item_id"] or value["provider_id"] != provider_id for value in existing):
            raise failure("identity_conflict", "This local item or QuickBooks ID already belongs to a different catalog link.")
        connection.execute("INSERT OR IGNORE INTO catalog_entity_mappings VALUES (?,?,?,?,?)",
                           (*scope(row), row["local_item_id"], provider_id))

    def claim(self, session_id, identifier):
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor, _ = self.authorize(connection, session_id, row)
            if row["state"] != "reserved":
                raise failure("publication_pending", "This catalog attempt is already being sent or reviewed. No second request was sent.")
            item = self.item_payload(row)
            if row["operation"] == "create" and item["Type"] != "Inventory":
                config = connection.execute(
                    "SELECT * FROM qbo_accounting_config WHERE realm_id=? AND environment=?",
                    (row["realm_id"], row["environment"]),
                ).fetchone()
                for field, column in (("IncomeAccountRef", "default_income_account_ref"), ("ExpenseAccountRef", "default_expense_account_ref")):
                    if field in item and (config is None or item[field]["value"] != config[column]):
                        raise failure("account_mapping_changed", "Review the current QuickBooks accounting mappings before publishing.")
            elif row["operation"] == "update":
                self.mapping(connection, row, item["Id"])
            connection.execute("UPDATE catalog_publications SET state='sending',updated_at=? WHERE id=?",
                               (self.now().isoformat(), identifier))
            self.audit(actor["email"], "dispatch", "catalog-publication", identifier, connection=connection)

    def confirm(self, session_id, identifier, remote):
        remote = validated_remote(remote)
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor, _ = self.authorize(connection, session_id, row)
            if row["state"] == "cancelled":
                raise failure("cancelled", "This unsent catalog attempt was cancelled.")
            if row["provider_id"] and row["provider_id"] != remote["Id"]:
                raise failure("identity_conflict", "QuickBooks returned a different catalog identity.")
            self.mapping(connection, row, remote["Id"])
            connection.execute("UPDATE catalog_publications SET state='confirmed',provider_id=?,updated_at=? WHERE id=?",
                               (remote["Id"], self.now().isoformat(), identifier))
            connection.execute("DELETE FROM catalog_publication_keys WHERE publication_id=?", (identifier,))
            self.audit(actor["email"], "confirm", "catalog-publication", identifier, connection=connection)
            return {"publication": self.public(self.record(connection, identifier)), "item": remote}

    def run(self, session_id, identifier, *, allow_send=False):
        row, context = self.check(session_id, identifier)
        item = self.item_payload(row)
        provider = self.provider_factory(context, lambda: self.check(session_id, identifier))
        expected_type = item.get("Type")
        if row["state"] == "confirmed":
            # Never label the original POST response as a current snapshot.
            remote = validated_remote(provider.read("item", row["provider_id"]))
            if remote["Id"] != row["provider_id"]:
                raise failure("identity_conflict", "QuickBooks returned a different catalog identity.")
            self.check(session_id, identifier)
            return {"publication": self.public(row), "item": remote, "created": False}
        if row["operation"] == "create":
            candidates = provider.items()
            self.check(session_id, identifier)
            matches = []
            for remote in candidates:
                if not isinstance(remote, dict) or not isinstance(remote.get("Name"), str) or not isinstance(remote.get("Sku", ""), str):
                    raise failure("provider_unconfirmed", "The complete catalog could not be verified.")
                overlaps = (remote["Name"].strip().casefold() == item["Name"].casefold()
                            or (item.get("Sku", "").strip() and remote.get("Sku", "").strip().casefold() == item["Sku"].strip().casefold()))
                if overlaps:
                    if not same_identity(item, remote):
                        raise failure("identity_conflict", "QuickBooks has a conflicting name, SKU or item type. Review the original catalog item.")
                    matches.append(validated_remote(remote))
            if len(matches) > 1:
                raise failure("identity_conflict", "More than one QuickBooks item matches this proposal.")
            if matches:
                result = self.confirm(session_id, identifier, matches[0])
                return {**result, "created": False}
        else:
            remote = validated_remote(provider.read("item", item["Id"]))
            expected_type = remote["Type"]
            self.check(session_id, identifier)
            if remote["Id"] != item["Id"]:
                raise failure("identity_conflict", "QuickBooks returned a different catalog identity.")
            if "Type" in item and item["Type"] != remote["Type"]:
                raise failure("identity_conflict", "The QuickBooks item type changed after review. Keep the original proposal for review.")
            if remote["Type"] == "Inventory" and item.get("Type") != "Inventory":
                raise failure("inventory_review", "Refresh and explicitly review this inventory item's type before publishing its changes.")
            if same_values(item, remote):
                return {**self.confirm(session_id, identifier, remote), "created": False}
            if remote["SyncToken"] != item["SyncToken"]:
                raise failure("review_changed", "QuickBooks changed after review. Cancel this unsent attempt and compare the new values.")
            if remote["Type"] == "Inventory" and item["Active"] != remote["Active"]:
                raise failure("inventory_lifecycle_review", "Inventory activation changes require a separate stock and accounting review in QuickBooks. This proposal has not been sent.")
        if not allow_send or row["state"] != "reserved":
            raise failure("outcome_unknown", "QuickBooks has not confirmed the original request. Keep this attempt for review; do not create another item.")
        if row["operation"] == "create" and item["Type"] == "Inventory":
            # These are per-item, explicitly reviewed accounts, not silently
            # borrowed service defaults. Validate in the original realm/grant.
            validate_inventory_accounts(item, provider)
        if "PrefVendorRef" in item:
            vendor = provider.read("vendor", item["PrefVendorRef"]["value"])
            if vendor.get("Id") != item["PrefVendorRef"]["value"] or vendor.get("Active") is not True:
                raise failure("vendor_changed", "Review the item's active preferred vendor before publishing.")
        self.check(session_id, identifier)
        claimed = False
        def claim():
            nonlocal claimed
            self.claim(session_id, identifier)
            claimed = True
        try:
            outbound = dict(item)
            if row["operation"] == "update":
                outbound.pop("Type", None)
            remote = validated_remote(provider.write(outbound, row["request_id"], claim))
            if row["operation"] == "update":
                valid = remote["Id"] == item["Id"] and remote["Type"] == expected_type and same_values(item, remote)
            else:
                valid = same_identity(item, remote) and same_values(item, remote)
            if not valid:
                raise failure("provider_unconfirmed", "QuickBooks did not confirm the reviewed item values.")
            return {**self.confirm(session_id, identifier, remote), "created": row["operation"] == "create"}
        except Exception:
            # A crash may leave 'sending'; both states forbid resending. Do not
            # release on a timeout, malformed body, non-2xx or local-save failure.
            if claimed:
                with self.database() as connection:
                    connection.execute("UPDATE catalog_publications SET state='unknown',updated_at=? WHERE id=? AND state='sending'",
                                       (self.now().isoformat(), identifier))
            raise

    def publish(self, session_id, payload):
        row = self.reserve(session_id, payload)
        return self.run(session_id, row["id"], allow_send=True)

    def context(self, session_id, payload):
        """Business-session discovery and mapped-item read, never link adoption.

        The caller supplies only local identity. Pin current authorization,
        account defaults and mapping across every provider suspension. No
        reservation, provider write or inferred mapping is made by this GET.
        """
        if not isinstance(payload, dict) or set(payload) != {"companyID", "localItemID"}:
            raise failure("invalid_query", "Choose one original business catalog item.", 400)
        company, item_id = canonical_uuid(payload["companyID"]), canonical_uuid(payload["localItemID"])

        def snapshot(connection, intent):
            _, grant = self.authorize(connection, session_id, intent, require_grant="grant_fingerprint" in intent)
            mapping = connection.execute(
                "SELECT provider_id FROM catalog_entity_mappings WHERE company_id=? AND realm_id=? AND environment=? AND local_item_id=?",
                (*scope(intent), item_id),
            ).fetchone()
            config = connection.execute(
                "SELECT * FROM qbo_accounting_config WHERE realm_id=? AND environment=?",
                (intent["realm_id"], intent["environment"]),
            ).fetchone()
            return grant, mapping[0] if mapping else None, dict(config) if config else None

        with self.database() as connection:
            grant = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
            if grant is None:
                # Authorize the actor/company before disclosing connection state.
                self.authorize(connection, session_id, {"company_id": company, "realm_id": "missing", "environment": "sandbox"}, False)
            intent = {"company_id": company, "realm_id": grant["realm_id"], "environment": grant["environment"]}
            grant, provider_id, config = snapshot(connection, intent)
            reference(intent["realm_id"])
            if intent["environment"] not in ("sandbox", "production"):
                raise failure("provider_changed", "Review the business QuickBooks connection.")
            intent["grant_fingerprint"] = grant["grant_fingerprint"]

        def check():
            with self.database() as connection:
                _, current_id, current_config = snapshot(connection, intent)
                if current_id != provider_id or current_config != config:
                    raise failure("review_changed", "The saved item link or accounting setup changed. Refresh the original item.")

        remote = None
        if provider_id is not None:
            reference(provider_id)
            remote = validated_remote(self.provider_factory(grant, check).read("item", provider_id))
            if remote["Id"] != provider_id:
                raise failure("identity_conflict", "QuickBooks returned a different catalog identity.")
            # Only supported pricebook evidence, never arbitrary provider data.
            allowed = {"Id", "SyncToken", "Name", "Type", "Description", "Sku", "PurchaseDesc", "UnitPrice",
                       "PurchaseCost", "Taxable", "Active", "IncomeAccountRef", "ExpenseAccountRef", "PrefVendorRef"} | INVENTORY_CREATE_FIELDS
            remote = {key: value for key, value in remote.items() if key in allowed}
            for key, value in list(remote.items()):
                if key.endswith("Ref"):
                    if not isinstance(value, dict):
                        raise failure("provider_unconfirmed", "QuickBooks returned incomplete accounting references.")
                    remote[key] = {"value": reference(value.get("value"))}
                    if isinstance(value.get("name"), str) and len(value["name"]) <= 500:
                        remote[key]["name"] = value["name"]
        check()

        def account(kind):
            value = config.get("default_" + kind + "_account_ref") if config else None
            return {"value": reference(value)} if value else None

        return {"companyID": company, "localItemID": item_id, "realmID": intent["realm_id"],
                "environment": intent["environment"], "protocolVersion": 1,
                "connectionRevision": hashlib.sha256(canonical(["job-billing-connection-v1", grant["grant_fingerprint"]]).encode()).hexdigest(),
                "incomeAccount": account("income"), "expenseAccount": account("expense"), "item": remote}

    def list_for_item(self, session_id, company_id, item_id):
        company_id, item_id = canonical_uuid(company_id), canonical_uuid(item_id)
        with self.database() as connection:
            grant = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
            if grant is None:
                raise failure("provider_changed", "Connect the original QuickBooks company.")
            intent = {"company_id": company_id, "realm_id": grant["realm_id"], "environment": grant["environment"]}
            self.authorize(connection, session_id, intent, require_grant=False)
            rows = connection.execute(
                """SELECT * FROM catalog_publications WHERE company_id=? AND realm_id=? AND environment=?
                   AND local_item_id=? ORDER BY created_at DESC LIMIT 100""", (*scope(intent), item_id),
            ).fetchall()
            return [self.public(row) for row in rows]

    def cancel(self, session_id, identifier):
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor, _ = self.authorize(connection, session_id, row)
            if row["state"] != "reserved":
                raise failure("cannot_cancel", "Only an unsent catalog proposal can be cancelled. Recover the original result instead.")
            connection.execute("UPDATE catalog_publications SET state='cancelled',updated_at=? WHERE id=?",
                               (self.now().isoformat(), identifier))
            connection.execute("DELETE FROM catalog_publication_keys WHERE publication_id=?", (identifier,))
            self.audit(actor["email"], "cancel", "catalog-publication", identifier, connection=connection)
            return {"publication": self.public(self.record(connection, identifier))}
