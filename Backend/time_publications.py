"""Office-reviewed time publication through the shared business connection.

Prepare is read-only at QBO. Confirm consumes one durable dispatch transition;
neither a lost reply nor recovery can repeat that transition. Client time-review
metadata is retained as source evidence, not mistaken for server approval.
"""
from __future__ import annotations

import json
import math
import re
import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

try:
    from Backend.time_worker_mappings import TimeWorkerMappings, digest, email, epoch, worker_reference
    from Backend.catalog_publications import canonical, failure, scope
    from Backend.payment_attempts import AttemptError, canonical_uuid, reference
except ModuleNotFoundError:
    from time_worker_mappings import TimeWorkerMappings, digest, email, epoch, worker_reference
    from catalog_publications import canonical, failure, scope
    from payment_attempts import AttemptError, canonical_uuid, reference


SCHEMA = """
CREATE TABLE IF NOT EXISTS time_publications (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, realm_id TEXT NOT NULL,
 environment TEXT NOT NULL, local_entry_id TEXT NOT NULL, worker_email TEXT NOT NULL,
 request_hash TEXT NOT NULL, payload_hash TEXT NOT NULL, payload_ciphertext TEXT NOT NULL,
 grant_fingerprint TEXT NOT NULL, actor_email TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('reserved','sending','unknown','confirmed','cancelled')),
 receipt_ciphertext TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS time_original_entry ON time_publications
 (company_id,local_entry_id) WHERE state!='cancelled';
CREATE TABLE IF NOT EXISTS time_entity_mappings (
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 local_entry_id TEXT NOT NULL, provider_id TEXT NOT NULL,
 PRIMARY KEY(company_id,local_entry_id),
 UNIQUE(company_id,realm_id,environment,provider_id)
);
"""


def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)


ACTIVITIES = {"job": "Job Labor", "travel": "Travel", "supply_run": "Supply Run",
              "shop_warehouse": "Shop / Warehouse", "training": "Training", "meeting": "Meeting",
              "administrative": "Administrative", "paid_break": "Paid Break", "general": "General"}


def instant(value):
    try:
        if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})", value):
            raise ValueError()
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise failure("invalid_time", "Use complete clock and approval times with their UTC offsets.", 400) from None


def text(value, maximum):
    if (not isinstance(value, str) or len(value) > maximum
            or any((ord(c) < 32 and c not in "\n\t") or ord(c) == 127 for c in value)):
        raise failure("invalid_time", "Review the time-entry note and its length.", 400)
    return value


def validated_request(payload, now):
    required = {"companyID", "realmID", "environment", "connectionRevision", "localEntryID", "workerEmail",
                "mappingRevision", "entryRevision", "clockIn", "clockOut", "timeZone", "payableMinutes",
                "activity", "notes", "serviceCallID", "localCustomerID", "localItemID", "reviewedByEmail", "reviewedAt"}
    if not isinstance(payload, dict) or set(payload) != required:
        raise failure("invalid_request", "Review the complete approved time entry. Unsupported payroll or project references require separate setup.", 400)
    if (payload["environment"] not in ("sandbox", "production") or type(payload["mappingRevision"]) is not int
            or not 1 <= payload["mappingRevision"] <= 2147483647 or payload["activity"] not in ACTIVITIES):
        raise failure("invalid_time", "Choose approved paid work and a reviewed worker mapping. Unpaid breaks remain in the local audit.", 400)
    start, end, reviewed = (instant(payload[key]) for key in ("clockIn", "clockOut", "reviewedAt"))
    try:
        if not isinstance(payload["timeZone"], str) or len(payload["timeZone"]) > 100:
            raise ValueError()
        zone = ZoneInfo(payload["timeZone"])
    except (ValueError, ZoneInfoNotFoundError):
        raise failure("invalid_time", "Choose the time entry's original business time zone.", 400) from None
    seconds = (end - start).total_seconds()
    minutes = max(1, math.floor(seconds / 60 + 0.5))
    if (not start < end <= reviewed <= now or seconds > 8760 * 3600
            or type(payload["payableMinutes"]) is not int or payload["payableMinutes"] != minutes
            or minutes > 8760 * 60):
        raise failure("invalid_time", "Review a completed interval and its approved rounded minutes before publishing.", 400)
    value = dict(payload)
    for key in ("companyID", "localEntryID"):
        value[key] = canonical_uuid(payload[key])
    for key in ("serviceCallID", "localCustomerID", "localItemID"):
        value[key] = canonical_uuid(payload[key]) if payload[key] is not None else None
    if bool(value["serviceCallID"]) != bool(value["localCustomerID"]) or (payload["activity"] == "job" and not value["serviceCallID"]):
        raise failure("invalid_time", "Job labor requires its original job and customer.", 400)
    reference(payload["realmID"])
    epoch(payload["connectionRevision"]); epoch(payload["entryRevision"])
    email(payload["workerEmail"]); email(payload["reviewedByEmail"])
    text(payload["notes"], 3000)
    if "GUNNAIRE-TIME" in payload["notes"].upper():
        raise failure("invalid_time", "Time identity markers are generated by the business service, not entered in notes.", 400)
    return value, start.astimezone(zone).date().isoformat()


def marker(identifier):
    return "GUNNAIRE-TIME:" + identifier.upper()


def publication_marker(identifier):
    return "GUNNAIRE-TIME-PUBLICATION:" + identifier.upper()


def same_time(document, remote):
    if not isinstance(remote, dict):
        return False
    for key in ("TxnDate", "NameOf", "Hours", "Minutes"):
        if remote.get(key) != document[key] or (key in ("Hours", "Minutes") and type(remote.get(key)) is not int):
            return False
    for key in ("EmployeeRef", "VendorRef", "CustomerRef", "ItemRef", "ProjectRef", "PayrollItemRef"):
        expected = document.get(key)
        actual = remote.get(key)
        if expected is None:
            if actual is not None:
                return False
        elif not isinstance(actual, dict) or actual.get("value") != expected["value"]:
            return False
    return True


def remote_evidence(remote):
    if not isinstance(remote, dict):
        raise failure("provider_unconfirmed", "QuickBooks did not return a complete time record.")
    reference(remote.get("Id")); reference(remote.get("SyncToken"))
    description = text(remote.get("Description", ""), 4000)
    # Never return rates, compensation, SSNs, addresses or arbitrary provider data.
    return {"providerID": remote["Id"], "syncToken": remote["SyncToken"], "description": description,
            "candidateRevision": digest({key: remote.get(key) for key in
                ("Id", "SyncToken", "TxnDate", "NameOf", "Hours", "Minutes", "EmployeeRef", "VendorRef",
                 "CustomerRef", "ItemRef", "ProjectRef", "PayrollItemRef", "Description")})}


class TimePublisher:
    def __init__(self, database, provider_factory, worker_factory, encrypt, decrypt, audit, now=None):
        self.database, self.provider_factory = database, provider_factory
        self.encrypt, self.decrypt, self.audit = encrypt, decrypt, audit
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.workers = TimeWorkerMappings(database, worker_factory, encrypt, decrypt, audit, self.now)

    def actor_company(self, connection, session_id, company):
        actor = self.workers.actor(connection, session_id)
        current = connection.execute("SELECT company_id FROM company_identity WHERE singleton=1").fetchone()
        if current is None or current[0] != company:
            raise failure("company_changed", "Reopen the original business workspace.", 403)
        return actor

    def record(self, connection, identifier):
        row = connection.execute("SELECT * FROM time_publications WHERE id=?", (canonical_uuid(identifier),)).fetchone()
        if row is None:
            raise failure("not_found", "Original time publication not found.", 404)
        return row

    def envelope(self, row):
        try:
            value = json.loads(self.decrypt(row["payload_ciphertext"]) or "")
            if (not isinstance(value, dict) or set(value) != {"request", "document", "mapping", "jobRevision", "actor", "scope", "publicationID"}
                    or digest(value) != row["payload_hash"] or value["scope"] != list(scope(row))
                    or value["publicationID"] != row["id"] or value["actor"] != row["actor_email"]
                    or value["request"]["localEntryID"] != row["local_entry_id"]
                    or value["request"]["workerEmail"] != row["worker_email"]
                    or digest(value["request"]) != row["request_hash"]):
                raise ValueError()
            return value
        except (ValueError, TypeError, KeyError):
            raise failure("storage_unavailable", "The original approved time could not be verified.", 503) from None

    def cipher(self, value):
        result = self.encrypt(canonical(value))
        if not isinstance(result, str) or not result:
            raise failure("storage_unavailable", "Secure time-review storage is unavailable.", 503)
        return result

    def public(self, row):
        envelope = self.envelope(row)
        receipt = None
        if (row["state"] == "confirmed") != (row["receipt_ciphertext"] is not None):
            raise failure("storage_unavailable", "The original time state and receipt disagree.", 503)
        if row["receipt_ciphertext"] is not None:
            try:
                saved = json.loads(self.decrypt(row["receipt_ciphertext"]) or "")
                if (set(saved) != {"publicationID", "reviewHash", "receipt"} or saved["publicationID"] != row["id"]
                        or saved["reviewHash"] != row["payload_hash"] or not isinstance(saved["receipt"], dict)):
                    raise ValueError()
                receipt = saved["receipt"]
                if (set(receipt) != {"providerID", "syncToken", "confirmedAt", "legacyAdoption"}
                        or type(receipt["legacyAdoption"]) is not bool):
                    raise ValueError()
                reference(receipt["providerID"]); reference(receipt["syncToken"]); instant(receipt["confirmedAt"])
            except (TypeError, ValueError, KeyError, AttemptError):
                raise failure("storage_unavailable", "The original time receipt could not be verified.", 503) from None
        return {"id": row["id"], "companyID": row["company_id"], "realmID": row["realm_id"], "environment": row["environment"],
                "localEntryID": row["local_entry_id"], "workerEmail": row["worker_email"], "state": row["state"],
                "entryRevision": envelope["request"]["entryRevision"], "reviewHash": row["payload_hash"], "preparedByEmail": row["actor_email"],
                "review": envelope["request"], "worker": envelope["mapping"], "timeActivity": envelope["document"],
                "receipt": receipt, "createdAt": row["created_at"], "updatedAt": row["updated_at"],
                "expiresAt": (instant(row["created_at"]) + timedelta(minutes=15)).isoformat()}

    def authority(self, connection, session_id, row, *, sending=False, pin=None):
        actor = self.actor_company(connection, session_id, row["company_id"])
        intent = {key: row[key] for key in ("company_id", "realm_id", "environment", "worker_email")}
        _, grant = self.workers.authorize(connection, session_id, intent)
        if pin is not None and grant["grant_fingerprint"] != pin:
            raise failure("grant_changed", "QuickBooks changed during this original time review. No second send is allowed.")
        if sending:
            if actor["email"] != row["actor_email"]:
                raise failure("actor_changed", "Only the original office reviewer may send this unsent proposal.", 403)
            if grant["grant_fingerprint"] != row["grant_fingerprint"]:
                raise failure("grant_changed", "Cancel this unsent proposal and review it after reconnecting QuickBooks.")
            if row["state"] not in ("reserved", "sending"):
                raise failure("cannot_send", "This request cannot be sent again. Recover the original result.")
            if not instant(row["created_at"]) <= self.now() < instant(row["created_at"]) + timedelta(minutes=15):
                raise failure("review_expired", "Cancel this unsent proposal and review the current time entry.")
            original = self.envelope(row)
            self.references(connection, original["request"], grant, original=original)
        return actor, grant

    def references(self, connection, request, grant, *, original=None):
        intent = {"company_id": request["companyID"], "realm_id": request["realmID"], "environment": request["environment"], "worker_email": request["workerEmail"]}
        mapping = self.workers.public(connection, self.workers.record(connection, intent), grant["grant_fingerprint"])
        if mapping is None or not mapping["usable"] or mapping["revision"] != request["mappingRevision"]:
            raise failure("mapping_changed", "Ask the administrator to review this worker's current QuickBooks mapping.")
        if original is not None and mapping != original["mapping"]:
            raise failure("mapping_changed", "The worker mapping changed after this time review.")
        refs, job_revision = {}, None
        for local, table, column, qbo in (("localCustomerID", "customer_entity_mappings", "local_customer_id", "CustomerRef"),
                                           ("localItemID", "catalog_entity_mappings", "local_item_id", "ItemRef")):
            if request[local] is not None:
                linked = connection.execute(f"SELECT provider_id FROM {table} WHERE company_id=? AND realm_id=? AND environment=? AND {column}=?",
                                            (*scope(intent), request[local])).fetchone()
                if linked is None:
                    raise failure("reference_missing", "Review the original customer's or service item's shared QuickBooks link.")
                refs[qbo] = {"value": reference(linked[0])}
        if request["serviceCallID"] is not None:
            job = connection.execute("SELECT local_customer_id,revision FROM billing_job_assignments WHERE company_id=? AND realm_id=? AND environment=? AND service_call_id=?",
                                     (*scope(intent), request["serviceCallID"])).fetchone()
            if job is None or job["local_customer_id"] != request["localCustomerID"]:
                raise failure("job_changed", "Save and verify this job's shared customer context before publishing its time.")
            job_revision = job["revision"]
        if original is not None and (job_revision != original["jobRevision"] or any(original["document"].get(key) != refs.get(key) for key in ("CustomerRef", "ItemRef"))):
            raise failure("reference_changed", "The job, customer or service-item link changed after review.")
        return mapping, refs, job_revision

    def fresh_references(self, provider, envelope):
        mapping = envelope["mapping"]
        selected = worker_reference(provider.read(mapping["kind"], mapping["providerID"]), mapping["kind"], mapping["providerID"])
        if selected["referenceRevision"] != mapping["referenceRevision"]:
            raise failure("worker_changed", "The QuickBooks worker changed. Ask the administrator to review the mapping again.")
        for key, kind in (("CustomerRef", "Customer"), ("ItemRef", "Item")):
            if key in envelope["document"]:
                identifier = envelope["document"][key]["value"]
                remote = provider.read(kind, identifier)
                if (not isinstance(remote, dict) or remote.get("Id") != identifier or remote.get("Active") is not True
                        or (kind == "Item" and remote.get("Type") != "Service")):
                    raise failure("reference_changed", "Review the active QuickBooks customer and service item before sending time.")

    def prepare(self, session_id, payload):
        request, posting_date = validated_request(payload, self.now())
        intent = {"company_id": request["companyID"], "realm_id": request["realmID"], "environment": request["environment"],
                  "worker_email": request["workerEmail"], "connection_revision": request["connectionRevision"]}
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, grant = self.workers.authorize(connection, session_id, intent)
            old = connection.execute("SELECT * FROM time_publications WHERE company_id=? AND local_entry_id=? AND state!='cancelled'",
                                     (request["companyID"], request["localEntryID"])).fetchone()
            if old is not None:
                if old["request_hash"] != digest(request) or old["actor_email"] != actor["email"]:
                    raise failure("publication_pending", "Keep this time entry with its original saved proposal. Recover or cancel that proposal first.")
                return {"publication": self.public(old)}
            if connection.execute("SELECT 1 FROM time_entity_mappings WHERE company_id=? AND local_entry_id=?",
                                  (request["companyID"], request["localEntryID"])).fetchone() is not None:
                raise failure("already_published", "This entry already has a shared QuickBooks time link. Recover that original link before continuing.")
            mapping, refs, job_revision = self.references(connection, request, grant)
            identifier = str(uuid.uuid4())
            description = "\n".join(filter(None, ["Activity: " + ACTIVITIES[request["activity"]], request["notes"],
                "Clocked " + request["clockIn"] + " - " + request["clockOut"], marker(request["localEntryID"]), publication_marker(identifier)]))
            document = {"TxnDate": posting_date, "NameOf": mapping["kind"], mapping["kind"] + "Ref": {"value": mapping["providerID"]},
                        "Hours": request["payableMinutes"] // 60, "Minutes": request["payableMinutes"] % 60,
                        "Description": text(description, 4000), **refs}
            envelope = {"request": request, "document": document, "mapping": mapping, "jobRevision": job_revision,
                        "actor": actor["email"], "scope": list(scope(intent)), "publicationID": identifier}
            now = self.now().isoformat()
            connection.execute("INSERT INTO time_publications VALUES (?,?,?,?,?,?,?,?,?,?,?,'reserved',NULL,?,?)",
                               (identifier, *scope(intent), request["localEntryID"], request["workerEmail"], digest(request), digest(envelope),
                                self.cipher(envelope), grant["grant_fingerprint"], actor["email"], now, now))
            self.audit(actor["email"], "prepare", "time-publication", identifier, connection=connection)
            row = dict(self.record(connection, identifier))
        # Preparation stores intent but does not dispatch. Provider failure leaves
        # an explicit recoverable reservation, not a lost or silently changed draft.
        self.fresh_references(self.provider_factory(grant, lambda: self.check(session_id, identifier, sending=True)), envelope)
        self.check(session_id, identifier, sending=True)
        return {"publication": self.public(row)}

    def check(self, session_id, identifier, *, sending=False, pin=None):
        with self.database() as connection:
            row = self.record(connection, identifier)
            _, grant = self.authority(connection, session_id, row, sending=sending, pin=pin)
            if row["state"] == "cancelled":
                raise failure("cancelled", "This unsent time proposal was cancelled.")
            self.envelope(row)
            return dict(row), grant

    def list_for_entry(self, session_id, payload):
        if not isinstance(payload, dict) or set(payload) != {"companyID", "localEntryID"}:
            raise failure("invalid_query", "Choose one original business time entry.", 400)
        company, entry = canonical_uuid(payload["companyID"]), canonical_uuid(payload["localEntryID"])
        with self.database() as connection:
            self.actor_company(connection, session_id, company)
            rows = connection.execute("SELECT * FROM time_publications WHERE company_id=? AND local_entry_id=? ORDER BY created_at,id", (company, entry)).fetchall()
            return {"publications": [self.public(row) for row in rows]}

    def decision(self, session_id, identifier, payload, *, adoption=False):
        fields = {"companyID", "entryRevision", "reviewHash"} | ({"providerID", "candidateRevision"} if adoption else set())
        if not isinstance(payload, dict) or set(payload) != fields:
            raise failure("invalid_request", "Confirm the original reviewed time values only.", 400)
        canonical_uuid(payload["companyID"]); epoch(payload["entryRevision"]); epoch(payload["reviewHash"])
        row, grant = self.check(session_id, identifier)
        if (row["company_id"] != payload["companyID"] or row["payload_hash"] != payload["reviewHash"]
                or self.envelope(row)["request"]["entryRevision"] != payload["entryRevision"]):
            raise failure("review_changed", "The time entry changed. Keep the original proposal for recovery.")
        if row["state"] != "reserved":
            if adoption:
                raise failure("cannot_adopt", "Only an unsent proposal can adopt a reviewed legacy record.")
            return self.recover(session_id, identifier)
        if adoption:
            reference(payload["providerID"]); epoch(payload["candidateRevision"])
        row, grant = self.check(session_id, identifier, sending=True)
        pin = grant["grant_fingerprint"]
        provider = self.provider_factory(grant, lambda: self.check(session_id, identifier, sending=True, pin=pin))
        envelope = self.envelope(row)
        self.fresh_references(provider, envelope)
        candidate, legacy = self.find(provider, row, envelope)
        if candidate is not None:
            evidence = remote_evidence(candidate)
            if legacy:
                if not adoption:
                    return {"publication": self.public(row), "legacyCandidate": evidence, "needsLegacyReview": True}
                if evidence["providerID"] != payload["providerID"] or evidence["candidateRevision"] != payload["candidateRevision"]:
                    raise failure("candidate_changed", "The existing time record changed. Review its current values before linking it.")
            elif adoption:
                raise failure("candidate_changed", "Recover this application's original publication instead of adopting another record.")
            return self.confirm_result(session_id, identifier, candidate, pin=pin, legacy=legacy)
        if adoption:
            raise failure("candidate_changed", "The exact existing time record was not found. No new record was sent.")
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            fresh = self.record(connection, identifier)
            actor, _ = self.authority(connection, session_id, fresh, sending=True, pin=pin)
            if fresh["state"] != "reserved":
                raise failure("cannot_send", "Another request already claimed this time entry. Recover its original result.")
            if connection.execute("SELECT 1 FROM time_entity_mappings WHERE company_id=? AND local_entry_id=?",
                                  (fresh["company_id"], fresh["local_entry_id"])).fetchone() is not None:
                raise failure("already_published", "This time entry was already linked. Recover its original result.")
            connection.execute("UPDATE time_publications SET state='sending',updated_at=? WHERE id=?", (self.now().isoformat(), identifier))
            self.audit(actor["email"], "approve-and-dispatch", "time-publication", identifier, connection=connection)
        try:
            remote = provider.create(envelope["document"], "ga-time-" + identifier)
            if not same_time(envelope["document"], remote) or remote.get("Description") != envelope["document"]["Description"]:
                raise failure("provider_unconfirmed", "QuickBooks did not confirm the exact approved time values.")
            return self.confirm_result(session_id, identifier, remote, pin=pin)
        except Exception:
            # Includes failures after dispatch/response and database confirmation.
            # Preserve a concurrent successful recovery, never reset to reserved.
            with self.database() as connection:
                connection.execute("UPDATE time_publications SET state='unknown',updated_at=? WHERE id=? AND state='sending'",
                                   (self.now().isoformat(), identifier))
            raise

    def find(self, provider, row, envelope):
        values = provider.activities()
        if not isinstance(values, list):
            raise failure("provider_unconfirmed", "The complete QuickBooks time list could not be checked.")
        matches, seen = [], set()
        identity, attempt = marker(row["local_entry_id"]), publication_marker(row["id"])
        for value in values:
            if not isinstance(value, dict):
                raise failure("provider_unconfirmed", "QuickBooks returned an incomplete time list.")
            identifier = reference(value.get("Id"))
            if identifier in seen:
                raise failure("provider_unconfirmed", "The QuickBooks time list changed while checking pages. Try read-only recovery again.")
            seen.add(identifier)
            description = text(value.get("Description", ""), 4000)
            if identity in description.upper() or attempt in description.upper():
                lines = description.splitlines()
                if (lines.count(identity) != 1 or any(line.startswith("GUNNAIRE-TIME:") and line != identity for line in lines)
                        or ("GUNNAIRE-TIME-PUBLICATION:" in description and lines.count(attempt) != 1)):
                    raise failure("time_identity_conflict", "A partial or conflicting time marker needs office review. No new time was sent.")
                if (not same_time(envelope["document"], value)
                        or (attempt in lines and description != envelope["document"]["Description"])):
                    raise failure("time_values_conflict", "An existing time marker has different hours, worker, date or job references. Review it in QuickBooks.")
                remote_evidence(value)
                matches.append((value, attempt not in lines))
        if len(matches) > 1:
            raise failure("time_identity_conflict", "Multiple time records match this entry. Resolve them in QuickBooks before continuing.")
        return matches[0] if matches else (None, False)

    def confirm_result(self, session_id, identifier, remote, *, pin, legacy=False):
        evidence = remote_evidence(remote)
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor, _ = self.authority(connection, session_id, row, sending=legacy, pin=pin)
            if row["state"] == "cancelled" or (legacy and row["state"] != "reserved"):
                raise failure("cannot_confirm", "This proposal is no longer available for that decision.")
            envelope = self.envelope(row)
            if not same_time(envelope["document"], remote):
                raise failure("time_values_conflict", "QuickBooks time no longer matches the original approved values.")
            links = connection.execute("SELECT * FROM time_entity_mappings WHERE company_id=? AND (local_entry_id=? OR (realm_id=? AND environment=? AND provider_id=?))",
                                       (row["company_id"], row["local_entry_id"], row["realm_id"], row["environment"], evidence["providerID"])).fetchall()
            if any(value["local_entry_id"] != row["local_entry_id"] or value["provider_id"] != evidence["providerID"]
                   or scope(value) != scope(row) for value in links):
                raise failure("time_identity_conflict", "This time entry or QuickBooks record already belongs to another original link.")
            if row["state"] == "confirmed":
                return {"publication": self.public(row)}
            connection.execute("INSERT OR IGNORE INTO time_entity_mappings VALUES (?,?,?,?,?)", (*scope(row), row["local_entry_id"], evidence["providerID"]))
            receipt = {"publicationID": identifier, "reviewHash": row["payload_hash"],
                       "receipt": {"providerID": evidence["providerID"], "syncToken": evidence["syncToken"],
                                   "confirmedAt": self.now().isoformat(), "legacyAdoption": legacy}}
            connection.execute("UPDATE time_publications SET state='confirmed',receipt_ciphertext=?,updated_at=? WHERE id=?",
                               (self.cipher(receipt), self.now().isoformat(), identifier))
            self.audit(actor["email"], "adopt-legacy" if legacy else "confirm", "time-publication", identifier, connection=connection)
            return {"publication": self.public(self.record(connection, identifier))}

    def recover(self, session_id, identifier):
        row, grant = self.check(session_id, identifier)
        if row["state"] == "confirmed":
            return {"publication": self.public(row)}  # Original receipt, not a claim of current QBO values.
        pin = grant["grant_fingerprint"]
        provider = self.provider_factory(grant, lambda: self.check(session_id, identifier, pin=pin))
        candidate, legacy = self.find(provider, row, self.envelope(row))
        fresh, _ = self.check(session_id, identifier, pin=pin)
        if candidate is not None and not legacy and fresh["state"] in ("sending", "unknown", "confirmed"):
            return self.confirm_result(session_id, identifier, candidate, pin=pin)
        result = {"publication": self.public(fresh)}
        if candidate is not None:
            result.update(legacyCandidate=remote_evidence(candidate), needsLegacyReview=True)
        return result  # No candidate never authorizes another POST, even after reconnection.

    def cancel(self, session_id, identifier, payload):
        if not isinstance(payload, dict) or set(payload) != {"companyID", "reviewHash"}:
            raise failure("invalid_request", "Cancel the exact unsent proposal.", 400)
        canonical_uuid(payload["companyID"]); epoch(payload["reviewHash"])
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor = self.actor_company(connection, session_id, row["company_id"])
            if payload["companyID"] != row["company_id"] or payload["reviewHash"] != row["payload_hash"]:
                raise failure("review_changed", "Keep the original time proposal.")
            if row["state"] not in ("reserved", "cancelled"):
                raise failure("cannot_cancel", "Only an unsent time proposal can be cancelled. Recover the original result instead.")
            if row["state"] == "reserved":
                connection.execute("UPDATE time_publications SET state='cancelled',updated_at=? WHERE id=?", (self.now().isoformat(), identifier))
                self.audit(actor["email"], "cancel", "time-publication", identifier, connection=connection)
            return {"publication": self.public(self.record(connection, identifier))}
