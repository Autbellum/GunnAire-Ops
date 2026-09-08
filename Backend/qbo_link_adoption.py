"""Reviewed adoption of existing QBO identities; provider reads only.

An administrator reviews an immutable bounded batch, then confirms the exact
revision. This creates shared links, never replacement accounting entities.
"""
from __future__ import annotations

import hashlib
import json
import re
import uuid
from datetime import datetime, timedelta, timezone

try:
    from Backend import billing_publications, billing_assignments, customer_publications
    from Backend.catalog_publications import canonical, failure, scope
    from Backend.payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference
except ModuleNotFoundError:
    import billing_publications, billing_assignments, customer_publications
    from catalog_publications import canonical, failure, scope
    from payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference

SCHEMA = """
CREATE TABLE IF NOT EXISTS qbo_link_reviews (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, realm_id TEXT NOT NULL,
 environment TEXT NOT NULL, operation_id TEXT NOT NULL, grant_fingerprint TEXT NOT NULL,
 request_hash TEXT NOT NULL, payload_ciphertext TEXT NOT NULL, revision TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('review','confirmed','cancelled')),
 actor_email TEXT NOT NULL, created_at TEXT NOT NULL, expires_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 UNIQUE(company_id,realm_id,environment,operation_id)
);
"""


def initialize_schema(connection):
    connection.execute(SCHEMA)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def request_scope(value):
    if not isinstance(value, dict) or not {"companyID", "realmID", "environment"} <= set(value):
        raise failure("invalid_request", "Choose the original business and QuickBooks connection.", 400)
    if value["environment"] not in ("sandbox", "production"):
        raise failure("invalid_request", "Choose a supported QuickBooks environment.", 400)
    return {"company_id": canonical_uuid(value["companyID"]), "realm_id": reference(value["realmID"]), "environment": value["environment"]}


def validated_request(value):
    intent = request_scope(value)
    if set(value) != {"companyID", "realmID", "environment", "operationID", "connectionRevision", "links"}:
        raise failure("invalid_request", "Use only the supported link-review fields.", 400)
    epoch = value["connectionRevision"]
    if not isinstance(epoch, str) or not re.fullmatch(r"[0-9a-f]{64}", epoch):
        raise failure("invalid_request", "Refresh the original QuickBooks connection before reviewing links.", 400)
    intent.update(operation_id=canonical_uuid(value["operationID"]), connection_revision=epoch)
    if not isinstance(value["links"], list) or not 1 <= len(value["links"]) <= 25:
        raise failure("invalid_request", "Review between one and 25 existing records at a time.", 400)
    links, locals_seen, providers_seen = [], set(), set()
    for entry in value["links"]:
        if not isinstance(entry, dict) or not {"kind", "localID", "providerID", "localName"} <= set(entry):
            raise failure("invalid_request", "Choose the exact saved record and existing QuickBooks ID.", 400)
        kind = entry["kind"]
        if kind not in ("Customer", "Item", "Invoice", "Estimate"):
            raise failure("invalid_request", "Only customer, item, invoice and estimate links are supported.", 400)
        document = kind in ("Invoice", "Estimate")
        allowed = {"kind", "localID", "providerID", "localName"} | ({"localCustomerID", "serviceCallID"} if document else set())
        if set(entry) - allowed or (document and "localCustomerID" not in entry):
            raise failure("invalid_request", "Keep each document with its original customer and optional job.", 400)
        name = billing_publications.bounded_text(entry["localName"], 500)
        if not name.strip():
            raise failure("invalid_request", "Provide a readable saved-record name for review.", 400)
        item = {"kind": kind, "localID": canonical_uuid(entry["localID"]), "providerID": reference(entry["providerID"]), "localName": name}
        if document:
            item["localCustomerID"] = canonical_uuid(entry["localCustomerID"])
            if "serviceCallID" in entry:
                item["serviceCallID"] = canonical_uuid(entry["serviceCallID"])
        local_key, provider_key = (kind, item["localID"]), (kind, item["providerID"])
        if local_key in locals_seen or provider_key in providers_seen:
            raise failure("identity_conflict", "Each reviewed local and QuickBooks identity must appear exactly once.")
        locals_seen.add(local_key); providers_seen.add(provider_key); links.append(item)
    intent["links"] = sorted(links, key=lambda row: (row["kind"], row["localID"]))
    return intent


def evidence(entry, remote):
    if not isinstance(remote, dict) or remote.get("Id") != entry["providerID"]:
        raise failure("provider_unconfirmed", "QuickBooks returned a different record than the one selected.")
    token = reference(remote.get("SyncToken"))
    kind = entry["kind"]
    value = {"Id": remote["Id"], "SyncToken": token}
    if kind == "Customer":
        customer_publications.validated_remote(remote)
        value.update(customer_publications.public_customer(remote))
        notes = remote.get("Notes", "")
        markers = re.findall(r"GunnAireCustomerID:[^\s]+", notes)
        if markers and markers != [customer_publications.lineage(entry["localID"])]:
            raise failure("identity_conflict", "The QuickBooks customer belongs to a different saved record.")
        value["lineageHash"] = digest(markers)
    elif kind == "Item":
        if type(remote.get("Active")) is not bool or remote.get("Type") not in ("Service", "NonInventory", "Inventory", "Group"):
            raise failure("provider_unconfirmed", "Review the accounting item's type and active status.")
        name = billing_publications.bounded_text(remote.get("Name"), 500)
        if not name.strip():
            raise failure("provider_unconfirmed", "QuickBooks did not provide an item name.")
        value.update(Name=name, Active=remote["Active"], Type=remote["Type"])
        if remote["Type"] == "Group":
            value["ItemGroupDetail"] = billing_publications.group_definition(remote)
            if "PrintGroupedItems" in remote:
                if type(remote["PrintGroupedItems"]) is not bool:
                    raise failure("provider_unconfirmed", "Review the bundle's customer display setting.")
                value["PrintGroupedItems"] = remote["PrintGroupedItems"]
        for key in ("UnitPrice", "Taxable", "Sku"):
            if key in remote:
                if key == "UnitPrice":
                    billing_publications.number(remote[key], places=5)
                elif key == "Taxable" and type(remote[key]) is not bool:
                    raise failure("provider_unconfirmed", "Review the item's tax choice.")
                elif key == "Sku":
                    billing_publications.bounded_text(remote[key], 100)
                value[key] = remote[key]
    else:
        value["CustomerRef"] = billing_publications.ref(remote.get("CustomerRef"))
        for key in ("TotalAmt", "Balance"):
            if key == "TotalAmt" or kind == "Invoice":
                billing_publications.number(remote.get(key)); value[key] = remote[key]
        if kind == "Invoice" and value["Balance"] > value["TotalAmt"]:
            raise failure("provider_unconfirmed", "The invoice balance is not consistent with its total.")
        for key in ("DocNumber", "TxnDate"):
            if key in remote:
                value[key] = billing_publications.bounded_text(remote[key], 100)
        notes = remote.get("PrivateNote", "")
        if not isinstance(notes, str):
            raise failure("provider_unconfirmed", "QuickBooks returned invalid document identity evidence.")
        markers = [line.strip() for line in notes.splitlines() if line.strip().casefold().startswith(("gunnaire invoice id:", "gunnaire estimate id:"))]
        if markers and markers != [f"GunnAire {kind} ID: {entry['localID'].upper()}"]:
            raise failure("identity_conflict", "The accounting document belongs to a different saved record.")
        # Keep full lines/private notes out of the linking UI and encrypted review.
        # Their digest still detects changes even if a provider leaves SyncToken unchanged.
        value["contentHash"] = digest({key: remote[key] for key in ("Line", "PrivateNote", "CurrencyRef", "Deposit", "LinkedTxn", "TxnTaxDetail") if key in remote})
    return value


class LinkAdopter:
    def __init__(self, database, provider_factory, encrypt, decrypt, audit, now=None):
        self.database, self.provider_factory, self.encrypt, self.decrypt, self.audit = database, provider_factory, encrypt, decrypt, audit
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.billing = billing_publications.BillingPublisher(database, provider_factory, encrypt, decrypt, audit, self.now)

    def authorize(self, connection, session_id, intent, *, historical=False):
        actor = self.billing.actor(connection, session_id)
        if actor["role"] != "Admin":
            raise failure("administrator_required", "An administrator must review existing accounting links.", 403)
        company = connection.execute("SELECT company_id FROM company_identity WHERE singleton=1").fetchone()
        if company is None or company[0] != intent["company_id"]:
            raise failure("company_changed", "Reopen the original business workspace.", 403)
        grant = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
        if grant is None or grant["realm_id"] != intent["realm_id"] or grant["environment"] != intent["environment"]:
            raise failure("provider_changed", "Reconnect the original QuickBooks company.")
        fingerprint = grant_fingerprint(grant)
        # Reading/cancelling retained evidence never adopts links or calls QBO.
        # It still requires a current Admin session and the exact business/realm.
        if not historical and "grant_fingerprint" in intent.keys() and intent["grant_fingerprint"] != fingerprint:
            raise failure("grant_changed", "QuickBooks was reconnected. Review the links again before adopting them.")
        if not historical and "connection_revision" in intent.keys() and intent["connection_revision"] != billing_assignments.connection_revision(fingerprint):
            raise failure("grant_changed", "Refresh the original QuickBooks connection before reviewing links.")
        return actor, {**dict(grant), "grant_fingerprint": fingerprint}

    def check(self, session_id, intent):
        with self.database() as connection:
            return self.authorize(connection, session_id, intent)[1]

    def record(self, connection, identifier):
        row = connection.execute("SELECT * FROM qbo_link_reviews WHERE id=?", (canonical_uuid(identifier),)).fetchone()
        if row is None:
            raise failure("not_found", "Link review not found.", 404)
        return row

    def envelope(self, row):
        try:
            if hashlib.sha256(row["payload_ciphertext"].encode()).hexdigest() != row["revision"]:
                raise ValueError()
            value = json.loads(self.decrypt(row["payload_ciphertext"]) or "")
            binding = [row["id"], *scope(row), row["operation_id"], row["grant_fingerprint"], row["request_hash"]]
            if value["binding"] != binding or not isinstance(value["links"], list) or not 1 <= len(value["links"]) <= 25:
                raise ValueError()
            return value
        except (ValueError, TypeError, KeyError):
            raise failure("storage_unavailable", "The original link review could not be verified.", 503) from None

    def public(self, row):
        value = self.envelope(row)
        links = [{**entry["link"], "quickBooks": {key: item for key, item in entry["evidence"].items() if key not in ("contentHash", "lineageHash")}} for entry in value["links"]]
        return {"id": row["id"], "companyID": row["company_id"], "realmID": row["realm_id"], "environment": row["environment"],
                "operationID": row["operation_id"], "revision": row["revision"], "state": row["state"], "expiresAt": row["expires_at"], "links": links}

    def lookup(self, session_id, query):
        intent = request_scope(query)
        if set(query) - {"companyID", "realmID", "environment", "operationID"}:
            raise failure("invalid_query", "Choose the original business and review operation.", 400)
        with self.database() as connection:
            _, grant = self.authorize(connection, session_id, intent)
            row = None
            if "operationID" in query:
                row = connection.execute("SELECT * FROM qbo_link_reviews WHERE company_id=? AND realm_id=? AND environment=? AND operation_id=?",
                    (*scope(intent), canonical_uuid(query["operationID"]))).fetchone()
            if row is not None:
                self.authorize(connection, session_id, row, historical=True)
            return {"connectionRevision": billing_assignments.connection_revision(grant["grant_fingerprint"]), "review": self.public(row) if row else None}

    def preview(self, session_id, payload):
        intent = validated_request(payload)
        request_hash = digest(intent)
        grant = self.check(session_id, intent)
        intent["grant_fingerprint"] = grant["grant_fingerprint"]
        with self.database() as connection:
            existing = connection.execute("SELECT * FROM qbo_link_reviews WHERE company_id=? AND realm_id=? AND environment=? AND operation_id=?", (*scope(intent), intent["operation_id"])).fetchone()
            if existing is not None:
                self.authorize(connection, session_id, existing)
                if existing["request_hash"] != request_hash:
                    raise failure("review_changed", "This operation already has a different saved proposal.")
                return self.public(existing)
        provider = self.provider_factory(grant, lambda: self.check(session_id, intent))
        values = [{"link": entry, "evidence": evidence(entry, provider.read(entry["kind"], entry["providerID"]))} for entry in intent["links"]]
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, _ = self.authorize(connection, session_id, intent)
            existing = connection.execute("SELECT * FROM qbo_link_reviews WHERE company_id=? AND realm_id=? AND environment=? AND operation_id=?", (*scope(intent), intent["operation_id"])).fetchone()
            if existing is not None:
                if existing["request_hash"] != request_hash:
                    raise failure("review_changed", "This operation already has a different saved proposal.")
                return self.public(existing)
            self.mappings(connection, intent, values, write=False)
            identifier, now = str(uuid.uuid4()), self.now()
            envelope = {"binding": [identifier, *scope(intent), intent["operation_id"], grant["grant_fingerprint"], request_hash], "links": values}
            ciphertext = self.encrypt(canonical(envelope))
            revision = hashlib.sha256(ciphertext.encode()).hexdigest()
            connection.execute("INSERT INTO qbo_link_reviews VALUES (?,?,?,?,?,?,?,?,?,'review',?,?,?,?)",
                (identifier, *scope(intent), intent["operation_id"], grant["grant_fingerprint"], request_hash, ciphertext, revision,
                 actor["email"], now.isoformat(), (now + timedelta(minutes=15)).isoformat(), now.isoformat()))
            self.audit(actor["email"], "review", "qbo-link-adoption", identifier, connection=connection)
            return self.public(self.record(connection, identifier))

    def read(self, session_id, identifier):
        with self.database() as connection:
            row = self.record(connection, identifier)
            self.authorize(connection, session_id, row, historical=True)
            return self.public(row)

    def decide(self, session_id, identifier, revision, *, confirm):
        with self.database() as connection:
            row = dict(self.record(connection, identifier))
            grant = self.authorize(connection, session_id, row, historical=not confirm)[1]
            values = self.envelope(row)["links"]
            if not isinstance(revision, str) or revision != row["revision"]:
                raise failure("review_changed", "Confirm the exact original review revision.")
            if row["state"] != "review":
                if row["state"] == ("confirmed" if confirm else "cancelled"):
                    return self.public(row)
                raise failure("review_changed", "This review already has a different decision.")
            if confirm and self.now() >= datetime.fromisoformat(row["expires_at"]):
                raise failure("review_expired", "The review expired. Read the current records into a new review.")
        if confirm:
            provider = self.provider_factory(grant, lambda: self.check(session_id, row))
            for entry in values:
                link = entry["link"]
                if evidence(link, provider.read(link["kind"], link["providerID"])) != entry["evidence"]:
                    raise failure("provider_changed", "QuickBooks changed a reviewed record. Review the current values before linking.")
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            current = self.record(connection, identifier)
            actor, _ = self.authorize(connection, session_id, current, historical=not confirm)
            self.envelope(current)
            if current["revision"] != revision or current["state"] not in ("review", "confirmed" if confirm else "cancelled"):
                raise failure("review_changed", "The original review changed before confirmation.")
            if current["state"] != "review":
                return self.public(current)
            if confirm:
                if self.now() >= datetime.fromisoformat(current["expires_at"]):
                    raise failure("review_expired", "The review expired before confirmation. Review the current records again.")
                self.mappings(connection, current, values, write=True)
            connection.execute("UPDATE qbo_link_reviews SET state=?,updated_at=? WHERE id=?", ("confirmed" if confirm else "cancelled", self.now().isoformat(), current["id"]))
            self.audit(actor["email"], "adopt" if confirm else "cancel", "qbo-link-adoption", current["id"], connection=connection)
            return self.public(self.record(connection, current["id"]))

    def mappings(self, connection, intent, values, *, write):
        batch_customers = {entry["link"]["localID"]: entry["link"]["providerID"] for entry in values if entry["link"]["kind"] == "Customer"}
        for entry in values:
            link, remote = entry["link"], entry["evidence"]
            kind, local, provider = link["kind"], link["localID"], link["providerID"]
            document = kind in ("Invoice", "Estimate")
            table, column, journal = ("billing_entity_mappings", "local_document_id", "billing_publications") if document else (
                ("customer_entity_mappings", "local_customer_id", "customer_publications") if kind == "Customer" else ("catalog_entity_mappings", "local_item_id", "catalog_publications"))
            kind_clause, kind_args = (" AND document_type=?", (kind,)) if document else ("", ())
            rows = connection.execute(f"SELECT * FROM {table} WHERE company_id=? AND realm_id=? AND environment=?{kind_clause} AND ({column}=? OR provider_id=?)", (*scope(intent), *kind_args, local, provider)).fetchall()
            if any(row[column] != local or row["provider_id"] != provider or (document and row["local_customer_id"] != link["localCustomerID"]) for row in rows):
                raise failure("identity_conflict", "An existing shared link belongs to a different local or QuickBooks record.")
            pending = connection.execute(f"SELECT 1 FROM {journal} WHERE company_id=? AND realm_id=? AND environment=?{kind_clause} AND ({column}=? OR provider_id=?) AND state IN ('reserved','sending','unknown') LIMIT 1", (*scope(intent), *kind_args, local, provider)).fetchone()
            if pending:
                raise failure("publication_pending", "Recover or review the original publication before adopting its link.")
            if document:
                customer = connection.execute("SELECT provider_id FROM customer_entity_mappings WHERE company_id=? AND realm_id=? AND environment=? AND local_customer_id=?", (*scope(intent), link["localCustomerID"])).fetchone()
                expected = customer[0] if customer else batch_customers.get(link["localCustomerID"])
                if expected != remote["CustomerRef"]["value"]:
                    raise failure("customer_conflict", "The accounting document does not belong to the reviewed original customer.")
                binding = {**dict(intent), "document_type": kind, "local_document_id": local, "local_customer_id": link["localCustomerID"], "service_call_id": link.get("serviceCallID")}
                existing = connection.execute("SELECT * FROM billing_job_documents WHERE company_id=? AND realm_id=? AND environment=? AND document_type=? AND local_document_id=?", (*scope(intent), kind, local)).fetchone()
                if existing and (existing["local_customer_id"] != link["localCustomerID"] or existing["service_call_id"] != link.get("serviceCallID")):
                    raise failure("job_changed", "Retain the document's original job and customer binding.")
                if write:
                    connection.execute("INSERT OR IGNORE INTO billing_entity_mappings VALUES (?,?,?,?,?,?,?)", (*scope(intent), kind, local, link["localCustomerID"], provider))
                    self.billing.assignments.bind_document(connection, binding)
            elif write:
                connection.execute(f"INSERT OR IGNORE INTO {table} VALUES (?,?,?,?,?)", (*scope(intent), local, provider))
