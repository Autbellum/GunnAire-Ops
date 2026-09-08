"""Company-scoped, read-only QBO census/CDC journal.

Captured is deliberately not applied: these cursors prove durable provider
capture, never a native import, payment reconciliation, or webhook application.
Every observed version (including tombstones) remains encrypted and immutable.
"""
from __future__ import annotations

import hashlib
import json
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

try:
    from Backend.catalog_publications import canonical, failure, scope
    from Backend.payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference
except ModuleNotFoundError:
    from catalog_publications import canonical, failure, scope
    from payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference


# The thirteen accounting collections in the native Management refresh. This
# allowlist is not a claim that every other QBO entity has been integrated.
ENTITIES = frozenset(("Account", "Bill", "Customer", "Deposit", "Estimate", "Invoice", "Item",
                      "Payment", "PaymentMethod", "Purchase", "SalesReceipt", "Vendor", "VendorCredit"))
LIST_ENTITIES = frozenset(("Account", "Customer", "Item", "PaymentMethod", "Vendor"))
OVERLAP = timedelta(minutes=2)
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
MAX_CENSUS_BYTES = 64 * 1024 * 1024
SCHEMA = """
CREATE TABLE IF NOT EXISTS qbo_capture_cursors (
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 entity_type TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
 webhook_position INTEGER NOT NULL DEFAULT 0,
 captured_through TEXT, baseline_at TEXT, issue_code TEXT,
 grant_fingerprint TEXT NOT NULL, updated_at TEXT NOT NULL,
 PRIMARY KEY(company_id,realm_id,environment,entity_type)
);
CREATE TABLE IF NOT EXISTS qbo_capture_versions (
 sequence INTEGER PRIMARY KEY AUTOINCREMENT,
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, provider_updated_at TEXT NOT NULL,
 provider_status TEXT NOT NULL, payload_hash TEXT NOT NULL, payload_ciphertext TEXT NOT NULL,
 observed_at TEXT NOT NULL,
 UNIQUE(company_id,realm_id,environment,entity_type,entity_id,provider_updated_at,payload_hash)
);
CREATE INDEX IF NOT EXISTS qbo_capture_history ON qbo_capture_versions
 (company_id,realm_id,environment,entity_type,sequence);
CREATE TABLE IF NOT EXISTS qbo_capture_batches (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 entity_type TEXT NOT NULL, revision INTEGER NOT NULL, mode TEXT NOT NULL,
 requested_since TEXT NOT NULL, captured_through TEXT NOT NULL,
 census_count INTEGER NOT NULL, change_count INTEGER NOT NULL, new_version_count INTEGER NOT NULL,
 completed_at TEXT NOT NULL,
 UNIQUE(company_id,realm_id,environment,entity_type,revision)
);
"""


def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)


def timestamp(value):
    try:
        if not isinstance(value, str) or len(value) > 64 or "T" not in value:
            raise ValueError()
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError()
        return parsed.astimezone(timezone.utc)
    except (ValueError, OverflowError):
        raise failure("invalid_timestamp", "QuickBooks change evidence needs a dated, timezone-aware record.", 400) from None


def stamp(value):
    # Fixed precision makes SQLite's text ordering agree with temporal ordering.
    return value.astimezone(timezone.utc).isoformat(timespec="microseconds")


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def strict_json(raw):
    def invalid_constant(_):
        raise ValueError("nonfinite JSON value")
    try:
        return json.loads(raw, object_pairs_hook=unique_object, parse_constant=invalid_constant)
    except RecursionError:
        raise ValueError("JSON nesting limit exceeded") from None


def entity_name(value):
    if not isinstance(value, str) or value not in ENTITIES:
        raise failure("unsupported_entity", "This accounting collection needs its own synchronization contract.", 400)
    return value


def validated_scope(payload):
    if not isinstance(payload, dict) or set(payload) != {"companyID", "realmID", "environment", "entityType"}:
        raise failure("invalid_request", "Choose the original business, accounting company and collection.", 400)
    if payload["environment"] not in ("sandbox", "production"):
        raise failure("invalid_request", "Choose the original QuickBooks environment.", 400)
    return {"company_id": canonical_uuid(payload["companyID"]), "realm_id": reference(payload["realmID"]),
            "environment": payload["environment"], "entity_type": entity_name(payload["entityType"])}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def transport(request):
    """GET-only fixed accounting origin; never a general proxy or mutation API."""
    try:
        url = urllib.parse.urlsplit(request.full_url)
        query = urllib.parse.parse_qs(url.query, keep_blank_values=True, strict_parsing=True)
        if (url.scheme != "https" or url.hostname not in
                {"quickbooks.api.intuit.com", "sandbox-quickbooks.api.intuit.com"}
                or url.username is not None or url.password is not None or url.port not in (None, 443)
                or url.fragment or not re.fullmatch(r"/v3/company/[A-Za-z0-9._:-]+/(cdc|query)", url.path)
                or request.get_method() != "GET" or request.data is not None
                or any(len(values) != 1 for values in query.values())
                or query.get("minorversion") != ["75"]):
            raise ValueError()
        if url.path.endswith("/cdc"):
            if set(query) != {"minorversion", "entities", "changedSince"}:
                raise ValueError()
            entity_name(query["entities"][0])
            timestamp(query["changedSince"][0])
        elif set(query) != {"minorversion", "query"} or not re.fullmatch(
                r"SELECT (?:COUNT\(\*\)|\*) FROM (?:" + "|".join(sorted(ENTITIES)) +
                r")(?: WHERE Active IN \(true, false\))?(?: STARTPOSITION [1-9][0-9]* MAXRESULTS 100)?", query["query"][0]):
            raise ValueError()
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=20) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
            if len(raw) > MAX_RESPONSE_BYTES or not 200 <= response.status < 300:
                raise ValueError()
            result = strict_json(raw.decode("utf-8"))
            if not isinstance(result, dict) or "Fault" in result:
                raise ValueError()
            return result
    except urllib.error.HTTPError as error:
        if error.code == 429:
            raise failure("provider_throttled", "QuickBooks is busy. Retry this original capture later; its cursor has not advanced.", 503) from None
        raise failure("provider_unavailable", "QuickBooks changes could not be confirmed. The saved capture cursor is retained.", 502) from None
    except (urllib.error.URLError, TimeoutError, ValueError, UnicodeDecodeError, AttemptError):
        raise failure("provider_unavailable", "QuickBooks changes could not be confirmed. The saved capture cursor is retained.", 502) from None


def record_evidence(value, *, tombstone_allowed):
    if not isinstance(value, dict) or value.get("sparse") is True:
        raise failure("incomplete_record", "QuickBooks returned an incomplete accounting record.")
    identifier = reference(value.get("Id"))
    metadata = value.get("MetaData")
    updated = timestamp(metadata.get("LastUpdatedTime") if isinstance(metadata, dict) else None)
    deleted = value.get("status") == "Deleted"
    if "status" in value and value["status"] != "Deleted":
        raise failure("unsupported_status", "Review the accounting record's unrecognized lifecycle state.")
    if deleted and not tombstone_allowed:
        raise failure("incomplete_census", "The initial accounting collection changed while it was being read.")
    if not deleted:
        reference(value.get("SyncToken"))
    # Validate the whole payload (including nested amounts), not only its ID.
    try:
        raw = canonical(value)
    except (TypeError, ValueError, RecursionError):
        raise failure("incomplete_record", "QuickBooks returned invalid accounting record data.") from None
    return identifier, stamp(updated), "deleted" if deleted else "present", raw


class ChangeCaptureQBOProvider:
    def __init__(self, context, authorize, bearer_loader, send=None):
        reference(context["realm_id"])
        if context["environment"] not in ("sandbox", "production"):
            raise failure("provider_changed", "Reconnect the original accounting company.")
        self.context, self.authorize, self.bearer_loader = dict(context), authorize, bearer_loader
        self.send, self.bearer = send or transport, None
        self.census_started_at = None

    def request(self, resource, query):
        if resource not in ("cdc", "query"):
            raise failure("invalid_resource", "Unsupported change capture resource.", 400)
        self.authorize()
        if self.bearer is None:
            self.bearer = self.bearer_loader(self.context, "system:qbo-change-capture")
        self.authorize()
        origin = "https://sandbox-quickbooks.api.intuit.com" if self.context["environment"] == "sandbox" else "https://quickbooks.api.intuit.com"
        url = origin + "/v3/company/" + urllib.parse.quote(self.context["realm_id"], safe="") + "/" + resource
        url += "?" + urllib.parse.urlencode({"minorversion": "75", **query})
        result = self.send(urllib.request.Request(url, method="GET", headers={
            "Authorization": "Bearer " + self.bearer, "Accept": "application/json"}))
        self.authorize()
        if not isinstance(result, dict) or "Fault" in result:
            raise failure("provider_unavailable", "QuickBooks did not confirm the change capture response.", 502)
        return result

    def census(self, entity):
        entity_name(entity)
        self.census_started_at = None
        clause = " WHERE Active IN (true, false)" if entity in LIST_ENTITIES else ""
        def count():
            response = self.request("query", {"query": "SELECT COUNT(*) FROM " + entity + clause})
            observed = timestamp(response.get("time"))
            if self.census_started_at is None:
                self.census_started_at = observed
            elif observed < self.census_started_at:
                raise failure("incomplete_census", "QuickBooks returned inconsistent collection times.")
            value = response.get("QueryResponse")
            total = value.get("totalCount") if isinstance(value, dict) else None
            if type(total) is not int or not 0 <= total <= 100000:
                raise failure("incomplete_census", "The complete accounting collection count could not be verified.")
            return total
        total, records, seen, size = count(), [], set(), 0
        for start in range(1, total + 1, 100):
            group = self.request("query", {"query": f"SELECT * FROM {entity}{clause} STARTPOSITION {start} MAXRESULTS 100"}).get("QueryResponse")
            page = group.get(entity) if isinstance(group, dict) else None
            if (not isinstance(page, list) or len(page) != min(100, total - start + 1)
                    or group.get("startPosition") != start or group.get("maxResults") != len(page)
                    or "Fault" in group or group.get("sparse") is True):
                raise failure("incomplete_census", "Accounting pages changed or were incomplete. No capture was committed.")
            for value in page:
                identifier, _, _, raw = record_evidence(value, tombstone_allowed=False)
                if identifier in seen:
                    raise failure("incomplete_census", "QuickBooks repeated a record across accounting pages.")
                seen.add(identifier)
                size += len(raw.encode())
                if size > MAX_CENSUS_BYTES:
                    raise failure("census_too_large", "This accounting collection needs a staged initial import.")
                records.append(value)
        if count() != total:
            raise failure("incomplete_census", "The accounting collection changed during its initial capture.")
        return records

    def changes(self, entity, since):
        entity_name(entity)
        stamp_since = stamp(timestamp(since))
        result = self.request("cdc", {"entities": entity, "changedSince": stamp_since})
        response_time = timestamp(result.get("time"))
        envelopes = result.get("CDCResponse")
        if not isinstance(envelopes, list) or len(envelopes) != 1 or not isinstance(envelopes[0], dict):
            raise failure("incomplete_changes", "QuickBooks did not return a complete change-capture envelope.")
        groups = envelopes[0].get("QueryResponse")
        if not isinstance(groups, list) or len(groups) != 1 or not isinstance(groups[0], dict):
            raise failure("incomplete_changes", "QuickBooks did not confirm the requested accounting collection.")
        group = groups[0]
        if set(group) - {entity, "startPosition", "maxResults", "totalCount"}:
            raise failure("incomplete_changes", "QuickBooks returned a different or incomplete accounting collection.")
        records = group.get(entity, [])
        if (not isinstance(records, list) or type(group.get("maxResults")) is not int
                or group["maxResults"] != len(records) or group.get("startPosition", 1) != 1
                or ("totalCount" in group and (type(group["totalCount"]) is not int or group["totalCount"] != len(records)))):
            raise failure("incomplete_changes", "QuickBooks returned incomplete change counts. The original cursor is retained.")
        # Exactly 1000 is ambiguous: CDC has no documented pagination/end-time.
        # Never move changedSince forward to make a saturated result look complete.
        if len(records) >= 1000:
            raise failure("change_limit", "QuickBooks reached its change limit. A complete recovery is required before advancing this collection.")
        seen = set()
        for value in records:
            identifier, updated, _, _ = record_evidence(value, tombstone_allowed=True)
            if identifier in seen or timestamp(updated) < timestamp(stamp_since) or timestamp(updated) > response_time:
                raise failure("incomplete_changes", "QuickBooks returned repeated or inconsistently dated changes.")
            seen.add(identifier)
        if response_time < timestamp(stamp_since):
            raise failure("incomplete_changes", "QuickBooks returned an older change-capture response.")
        return records, response_time


class ChangeCapture:
    def __init__(self, database, provider_factory, encrypt, decrypt, audit, now=None):
        self.database, self.provider_factory = database, provider_factory
        self.encrypt, self.decrypt, self.audit = encrypt, decrypt, audit
        self.now = now or (lambda: datetime.now(timezone.utc))

    def authorize(self, connection, session_id, intent):
        actor = connection.execute("""SELECT s.*,u.role,u.is_active FROM auth_sessions s
            JOIN users u ON u.email=s.email WHERE s.id=?""", (session_id,)).fetchone()
        try:
            valid = (actor["revoked_at"] is None and actor["is_active"] and actor["role"] == "Admin"
                     and timestamp(actor["created_at"]) <= self.now() < timestamp(actor["expires_at"]))
        except (TypeError, AttemptError):
            valid = False
        if not valid:
            raise failure("administrator_required", "Sign in with current administrator access to reconcile company accounting.", 403)
        company = connection.execute("SELECT company_id FROM company_identity WHERE singleton=1").fetchone()
        if company is None or company[0] != intent["company_id"]:
            raise failure("company_changed", "Reopen the original business workspace.", 403)
        grant = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
        if grant is None or grant["realm_id"] != intent["realm_id"] or grant["environment"] != intent["environment"]:
            raise failure("provider_changed", "Reconnect the original QuickBooks company.")
        fingerprint = grant_fingerprint(grant)
        if "grant_fingerprint" in intent and intent["grant_fingerprint"] != fingerprint:
            raise failure("grant_changed", "QuickBooks was reconnected. Reopen the original capture before continuing.")
        return actor, {**dict(grant), "grant_fingerprint": fingerprint}

    @staticmethod
    def cursor(connection, intent):
        return connection.execute("""SELECT * FROM qbo_capture_cursors
            WHERE company_id=? AND realm_id=? AND environment=? AND entity_type=?""",
            (*scope(intent), intent["entity_type"])).fetchone()

    @staticmethod
    def event_has_version(connection, intent, event):
        """Only proof that dated provider records are available, NOT applied.

        Deleted IDs need actual CDC tombstones. A merge needs evidence for both
        identities; a survivor alone cannot stand in for the removed record.
        """
        def exists(identifier, deleted=False):
            return connection.execute("""SELECT 1 FROM qbo_capture_versions
                WHERE company_id=? AND realm_id=? AND environment=? AND entity_type=?
                AND entity_id=? AND provider_updated_at>=? AND (?=0 OR provider_status='deleted') LIMIT 1""",
                (*scope(intent), intent["entity_type"], identifier, stamp(timestamp(event["occurred_at"])), int(deleted))).fetchone() is not None
        if not exists(event["entity_id"], event["operation"] == "deleted"):
            return False
        if event["operation"] == "merged":
            return bool(event["deleted_entity_id"]) and exists(event["deleted_entity_id"], True)
        return True

    def capture(self, session_id, payload):
        intent = validated_scope(payload)
        started = self.now()
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, grant = self.authorize(connection, session_id, intent)
            intent["grant_fingerprint"] = grant["grant_fingerprint"]
            connection.execute("""INSERT INTO qbo_capture_cursors
                (company_id,realm_id,environment,entity_type,grant_fingerprint,updated_at)
                VALUES (?,?,?,?,?,?) ON CONFLICT DO NOTHING""",
                (*scope(intent), intent["entity_type"], grant["grant_fingerprint"], stamp(started)))
            original = dict(self.cursor(connection, intent))
            # Receipt order, not event time, identifies newly arrived webhook
            # notifications. An out-of-order event rewinds the CDC look-back.
            # Never use acknowledged_at: the legacy native path has no per-event
            # application proof and is not authoritative for this journal.
            event_position = original["webhook_position"]
            original_events = []
            event_since = None
            for event in connection.execute("""SELECT rowid AS position,* FROM qbo_webhook_events
                WHERE company_id=? AND realm_id=? AND environment=? AND REPLACE(entity_type,'-','')=?
                AND rowid>? ORDER BY rowid""",
                (*scope(intent), intent["entity_type"].lower(), event_position)):
                occurred = timestamp(event["occurred_at"])
                event_since = min(event_since, occurred) if event_since is not None else occurred
                original_events.append(dict(event))
        def authorize():
            with self.database() as connection:
                self.authorize(connection, session_id, intent)
                if self.cursor(connection, intent)["revision"] != original["revision"]:
                    raise failure("capture_superseded", "A newer capture already completed. Read its saved result.")
        provider = self.provider_factory({**grant, "company_id": intent["company_id"]}, authorize)
        since = timestamp(original["captured_through"]) - OVERLAP if original["captured_through"] else started - OVERLAP
        if event_since is not None:
            since = min(since, event_since - OVERLAP)
        bootstrap = original["baseline_at"] is None
        try:
            if since < started - timedelta(days=30):
                raise failure("history_gap", "This accounting collection has an older synchronization gap. Recover it before advancing the saved cursor.")
            if since > started:
                raise failure("clock_review", "Review the capture clock before replacing the saved accounting cursor.")
            # Encryptability is checked before any provider read or token refresh.
            self.encrypt(canonical({"scope": list(scope(intent)), "capture": "readiness"}))
            census = provider.census(intent["entity_type"]) if bootstrap else []
            census_barrier = getattr(provider, "census_started_at", None) or started
            if bootstrap:
                since = min(since, census_barrier - OVERLAP)
                if since < self.now() - timedelta(days=30):
                    raise failure("history_gap", "The initial collection took too long for complete change recovery.")
            changes, response_time = provider.changes(intent["entity_type"], stamp(since))
            through = min(started, response_time)
            if original["captured_through"] and through < timestamp(original["captured_through"]):
                raise failure("clock_review", "The accounting capture response is older than the saved cursor.")
            # Offset pagination is not a transaction. Equal counts alone cannot
            # prove that a deletion/insertion did not shift an unchanged record
            # across pages. Keep capturing history, but repeat the census until
            # CDC proves a quiet, complete enumeration interval.
            stable_baseline = not bootstrap or (response_time >= census_barrier and all(
                timestamp(value["MetaData"]["LastUpdatedTime"]) < census_barrier - OVERLAP for value in changes))
            encrypted = []
            for value in census + changes:
                identifier, updated, status, raw = record_evidence(value, tombstone_allowed=True)
                envelope = {"companyID": intent["company_id"], "realmID": intent["realm_id"],
                            "environment": intent["environment"], "entityType": intent["entity_type"], "record": value}
                encrypted.append((identifier, updated, status, hashlib.sha256(raw.encode()).hexdigest(), self.encrypt(canonical(envelope))))
            with self.database() as connection:
                connection.execute("BEGIN IMMEDIATE")
                self.authorize(connection, session_id, intent)
                if self.cursor(connection, intent)["revision"] != original["revision"]:
                    raise failure("capture_superseded", "A newer capture already completed. Read its saved result.")
                inserted = 0
                for identifier, updated, status, digest, ciphertext in encrypted:
                    inserted += connection.execute("""INSERT INTO qbo_capture_versions
                        (company_id,realm_id,environment,entity_type,entity_id,provider_updated_at,
                         provider_status,payload_hash,payload_ciphertext,observed_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING""",
                        (*scope(intent), intent["entity_type"], identifier, updated, status, digest, ciphertext, stamp(started))).rowcount
                missing_event_record = False
                for event in original_events:
                    if not self.event_has_version(connection, intent, event):
                        missing_event_record = True
                        break
                    event_position = event["position"]
                revision = original["revision"] + 1
                connection.execute("""UPDATE qbo_capture_cursors SET revision=?, captured_through=?,webhook_position=?,
                    baseline_at=COALESCE(baseline_at,?),issue_code=?,grant_fingerprint=?,updated_at=?
                    WHERE company_id=? AND realm_id=? AND environment=? AND entity_type=?""",
                    (revision, stamp(through), event_position, stamp(census_barrier) if stable_baseline else None,
                     "event_record_missing" if missing_event_record else (None if stable_baseline else "baseline_changed"),
                     intent["grant_fingerprint"], stamp(self.now()),
                     *scope(intent), intent["entity_type"]))
                identifier = str(uuid.uuid4())
                connection.execute("INSERT INTO qbo_capture_batches VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (identifier, *scope(intent), intent["entity_type"], revision, "baseline" if bootstrap else "incremental",
                     stamp(since), stamp(through), len(census), len(changes), inserted, stamp(self.now())))
                self.audit(actor["email"], "capture", "qbo-change-batch", identifier, connection=connection)
            # A status response is scoped/re-authorized again after the save.
            return self.read(session_id, payload, expected_grant=intent["grant_fingerprint"])
        except AttemptError as error:
            if error.code not in {"administrator_required", "company_changed", "provider_changed", "grant_changed", "capture_superseded"}:
                with self.database() as connection:
                    connection.execute("BEGIN IMMEDIATE")
                    self.authorize(connection, session_id, intent)
                    connection.execute("""UPDATE qbo_capture_cursors SET issue_code=?,updated_at=?
                        WHERE company_id=? AND realm_id=? AND environment=? AND entity_type=? AND revision=?""",
                        (error.code, stamp(self.now()), *scope(intent), intent["entity_type"], original["revision"]))
            raise

    def read(self, session_id, payload, *, after=0, through=None, expected_grant=None):
        intent = validated_scope(payload)
        if expected_grant is not None:
            intent["grant_fingerprint"] = expected_grant
        if type(after) is not int or after < 0 or (through is not None and (type(through) is not int or through < after)):
            raise failure("invalid_cursor", "Use the original saved history page cursor.", 400)
        with self.database() as connection:
            # One read transaction pins metadata and pages to the same snapshot.
            connection.execute("BEGIN")
            actor, grant = self.authorize(connection, session_id, intent)
            intent["grant_fingerprint"] = grant["grant_fingerprint"]
            cursor = self.cursor(connection, intent)
            legacy_count = connection.execute("""SELECT COUNT(*) FROM qbo_webhook_events
                WHERE realm_id=? AND REPLACE(entity_type,'-','')=? AND
                (company_id IS NULL OR environment IS NULL)""",
                (intent["realm_id"], intent["entity_type"].lower())).fetchone()[0]
            maximum = connection.execute("""SELECT COALESCE(MAX(sequence),0) FROM qbo_capture_versions
                WHERE company_id=? AND realm_id=? AND environment=? AND entity_type=?""",
                (*scope(intent), intent["entity_type"])).fetchone()[0]
            if through is None:
                through = maximum
            if through > maximum or after > through:
                raise failure("invalid_cursor", "The saved history page is not available for this company.", 400)
            rows = connection.execute("""SELECT sequence,entity_id,provider_updated_at,provider_status,payload_hash FROM qbo_capture_versions
                WHERE company_id=? AND realm_id=? AND environment=? AND entity_type=? AND sequence>? AND sequence<=?
                ORDER BY sequence LIMIT 51""", (*scope(intent), intent["entity_type"], after, through)).fetchall()
            versions, response_bytes = [], 0
            for row in rows[:50]:
                try:
                    encrypted = connection.execute("SELECT payload_ciphertext FROM qbo_capture_versions WHERE sequence=?",
                                                   (row["sequence"],)).fetchone()[0]
                    envelope = strict_json(self.decrypt(encrypted))
                    expected = {"companyID": intent["company_id"], "realmID": intent["realm_id"],
                                "environment": intent["environment"], "entityType": intent["entity_type"]}
                    if not isinstance(envelope, dict) or set(envelope) != set(expected) | {"record"} or any(envelope[key] != value for key, value in expected.items()):
                        raise ValueError()
                    identifier, updated, status, raw = record_evidence(envelope["record"], tombstone_allowed=True)
                    if (identifier != row["entity_id"] or updated != row["provider_updated_at"] or status != row["provider_status"]
                            or hashlib.sha256(raw.encode()).hexdigest() != row["payload_hash"]):
                        raise ValueError()
                except (ValueError, TypeError, RuntimeError, AttemptError):
                    raise failure("history_unavailable", "The original accounting history could not be verified. Restore it before applying changes.", 503) from None
                record_bytes = len(raw.encode())
                if record_bytes > MAX_RESPONSE_BYTES - 65536:
                    raise failure("history_record_too_large", "This accounting record needs a file-based history transfer.", 503)
                if response_bytes + record_bytes > MAX_RESPONSE_BYTES - 65536:
                    break
                response_bytes += record_bytes
                versions.append({"sequence": row["sequence"], "entityID": identifier, "updatedAt": updated,
                                 "status": status, "record": envelope["record"]})
            self.authorize(connection, session_id, intent)
        # Recheck against fresh state too: a SQLite read snapshot cannot observe
        # revocation committed during decryption.
        with self.database() as connection:
            self.authorize(connection, session_id, intent)
        return {**payload, "revision": cursor["revision"] if cursor else 0,
                "capturedThrough": cursor["captured_through"] if cursor else None,
                "baselineAt": cursor["baseline_at"] if cursor else None,
                "issueCode": cursor["issue_code"] if cursor else None,
                "legacyEventsNeedingReview": legacy_count,
                "applicationState": "not_applied", "versions": versions,
                "throughSequence": through, "nextAfterSequence": versions[-1]["sequence"] if len(rows) > len(versions) else None}
