"""Durable, company-owned QBO file publication; never an accounting write.

Reserve encrypted original bytes before dispatch. A sending/uncertain record
can only be reconciled by its exact server marker, never reset for another POST.
The current receipt UI is migrated separately; legacy unowned paths are not
silently adopted by this service.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import re
import uuid
from datetime import datetime, timezone

try:
    from Backend import billing_assignments, billing_publications
    from Backend.catalog_publications import canonical, failure, scope
    from Backend.payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference
except ModuleNotFoundError:
    import billing_assignments, billing_publications
    from catalog_publications import canonical, failure, scope
    from payment_attempts import AttemptError, canonical_uuid, grant_fingerprint, reference

MAX_FILE_BYTES = 25 * 1024 * 1024
MAX_BODY_BYTES = ((MAX_FILE_BYTES + 2) // 3) * 4 + 8192
TYPES = {"Invoice", "Estimate", "Bill", "Payment", "SalesReceipt", "Purchase"}
JOB_DOCUMENT_KINDS = {"service_report", "before_photo", "after_photo", "diagnostic_photo",
                      "equipment_data_plate_photo", "warranty_evidence", "customer_document",
                      "invoice_support", "estimate_support", "receipt", "other"}
MIME = {"pdf": {"application/pdf"}, "txt": {"text/plain"}, "rtf": {"application/rtf", "text/rtf"},
        "jpg": {"image/jpeg", "image/jpg"}, "jpeg": {"image/jpeg", "image/jpg"}, "png": {"image/png"},
        "gif": {"image/gif"}, "tif": {"image/tiff"}, "csv": {"text/csv"},
        "doc": {"application/msword"}, "docx": {"application/vnd.openxmlformats-officedocument.wordprocessingml.document"},
        "xls": {"application/vnd.ms-excel"}, "xlsx": {"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
        "ods": {"application/vnd.oasis.opendocument.spreadsheet"},
        "xml": {"application/xml", "text/xml"}, "ai": {"application/postscript"}, "eps": {"application/postscript"}}
STATES = {"reserved", "sending", "uncertain", "confirmed", "cancelled"}
METADATA_COLUMNS = "id,company_id,realm_id,environment,operation_id,grant_fingerprint,request_hash,content_key,payload_ciphertext,revision,state,provider_id,state_ciphertext,actor_email,created_at,updated_at"
SCHEMA = """
CREATE TABLE IF NOT EXISTS qbo_document_uploads (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, realm_id TEXT NOT NULL,
 environment TEXT NOT NULL, operation_id TEXT NOT NULL, grant_fingerprint TEXT NOT NULL,
 request_hash TEXT NOT NULL, content_key TEXT NOT NULL, payload_ciphertext TEXT NOT NULL,
 file_ciphertext TEXT NOT NULL, revision TEXT NOT NULL, state TEXT NOT NULL,
 provider_id TEXT, state_ciphertext TEXT NOT NULL, actor_email TEXT NOT NULL,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 UNIQUE(company_id,realm_id,environment,operation_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS qbo_document_upload_content
 ON qbo_document_uploads(company_id,realm_id,environment,content_key)
 WHERE state != 'cancelled';
CREATE INDEX IF NOT EXISTS qbo_document_upload_list
 ON qbo_document_uploads(company_id,realm_id,environment,id);
CREATE TABLE IF NOT EXISTS qbo_document_upload_operations (
 company_id TEXT NOT NULL, realm_id TEXT NOT NULL, environment TEXT NOT NULL,
 operation_id TEXT NOT NULL, request_hash TEXT NOT NULL, upload_id TEXT NOT NULL, payload_ciphertext TEXT NOT NULL,
 PRIMARY KEY(company_id,realm_id,environment,operation_id)
);
"""


def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def request_scope(value):
    if not isinstance(value, dict) or value.get("environment") not in ("sandbox", "production"):
        raise failure("invalid_request", "Choose the original business and QuickBooks connection.", 400)
    return {"company_id": canonical_uuid(value.get("companyID")), "realm_id": reference(value.get("realmID")),
            "environment": value["environment"]}


def file_content(value):
    if not isinstance(value, dict) or set(value) != {"filename", "contentType", "data"}:
        raise failure("invalid_file", "Choose the original supported file.", 400)
    name, mime, encoded = value["filename"], value["contentType"], value["data"]
    try:
        length = len(name.encode("utf-8")) if isinstance(name, str) else 0
    except UnicodeError:
        length = 0
    if (not isinstance(name, str) or not 1 <= length <= 255 or name != name.strip()
            or any(ord(c) < 32 or ord(c) == 127 or c in '/\\"' for c in name)
            or name in (".", "..") or not isinstance(mime, str) or mime not in MIME.get(name.rsplit(".", 1)[-1].lower(), set())
            or not isinstance(encoded, str) or not 1 <= len(encoded) <= ((MAX_FILE_BYTES + 2) // 3) * 4):
        raise failure("invalid_file", "Choose a supported file with a safe filename, up to 25 MB.", 400)
    try:
        data = base64.b64decode(encoded, validate=True)
        if not 1 <= len(data) <= MAX_FILE_BYTES or base64.b64encode(data).decode() != encoded:
            raise ValueError()
    except (ValueError, binascii.Error):
        raise failure("invalid_file", "The complete original file could not be verified.", 400) from None
    return {"filename": name, "contentType": mime, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}, data


def targets(value):
    if not isinstance(value, list) or len(value) > 4:
        raise failure("invalid_target", "Choose up to four exact related transactions.", 400)
    result = []
    for entry in value:
        if not isinstance(entry, dict) or set(entry) != {"type", "id"} or not isinstance(entry["type"], str) or entry["type"] not in TYPES:
            raise failure("invalid_target", "Choose a supported transaction type and original ID together.", 400)
        result.append({"type": entry["type"], "id": reference(entry["id"])})
    if len({(item["type"], item["id"]) for item in result}) != len(result):
        raise failure("invalid_target", "Each related transaction must appear only once.", 400)
    return sorted(result, key=lambda item: (item["type"], item["id"]))


def validated_request(value):
    expected = {"companyID", "realmID", "environment", "operationID", "connectionRevision", "file", "targets"}
    if not isinstance(value, dict) or set(value) not in (expected, expected | {"jobDocument"}):
        raise failure("invalid_request", "Use only the supported original-file upload fields.", 400)
    intent = request_scope(value)
    epoch = value["connectionRevision"]
    if not isinstance(epoch, str) or not re.fullmatch(r"[0-9a-f]{64}", epoch):
        raise failure("invalid_request", "Verify the original QuickBooks connection before saving an upload.", 400)
    metadata, data = file_content(value["file"])
    intent.update(operation_id=canonical_uuid(value["operationID"]), connection_revision=epoch,
                  file=metadata, targets=targets(value["targets"]))
    if "jobDocument" in value:
        intent["job_document"] = job_document(value["jobDocument"], intent["targets"])
    return intent, data


def job_document(value, destinations):
    expected = {"attachmentID", "serviceCallID", "localCustomerID", "customerQuickBooksID", "kind", "stage", "documents"}
    if (not isinstance(value, dict) or set(value) != expected
            or not isinstance(value["kind"], str) or value["kind"] not in JOB_DOCUMENT_KINDS
            or value["stage"] not in ("before", "after", "supporting")
            or not isinstance(value["documents"], list) or not 1 <= len(value["documents"]) <= 4):
        raise failure("invalid_job_document", "Keep the original job, customer and supported file context together.", 400)
    try:
        result = {key: canonical_uuid(value[key]) for key in ("attachmentID", "serviceCallID", "localCustomerID")}
        result.update(customerQuickBooksID=reference(value["customerQuickBooksID"]), kind=value["kind"], stage=value["stage"])
        documents = []
        for item in value["documents"]:
            if (not isinstance(item, dict) or set(item) != {"type", "localID", "id"}
                    or item["type"] not in ("Invoice", "Estimate")
                    or (value["kind"] == "invoice_support" and item["type"] != "Invoice")
                    or (value["kind"] == "estimate_support" and item["type"] != "Estimate")):
                raise ValueError()
            documents.append({"type": item["type"], "localID": canonical_uuid(item["localID"]), "id": reference(item["id"])})
        documents.sort(key=lambda item: (item["type"], item["id"]))
        if ([{"type": item["type"], "id": item["id"]} for item in documents] != destinations
                or len({(item["type"], item["localID"]) for item in documents}) != len(documents)):
            raise ValueError()
        result["documents"] = documents
        return result
    except (AttemptError, ValueError, TypeError):
        raise failure("invalid_job_document", "Use the exact saved invoice or estimate links for this job file.", 400) from None


def marker(row, intent):
    return f"GunnAire upload {row['id']} sha256 {intent['file']['sha256']}"


def upload_metadata(row, intent):
    return {"FileName": intent["file"]["filename"], "ContentType": intent["file"]["contentType"],
            "Note": marker(row, intent), "AttachableRef": [
                {"EntityRef": {"type": item["type"], "value": item["id"]}, "IncludeOnSend": False}
                for item in intent["targets"]]}


def confirmed_attachment(row, intent, remote):
    if not isinstance(remote, dict):
        raise failure("upload_unconfirmed", "QuickBooks has not confirmed the original file.")
    identifier = reference(remote.get("Id"))
    expected = upload_metadata(row, intent)
    refs = remote.get("AttachableRef", [])
    if not isinstance(refs, list):
        raise failure("upload_unconfirmed", "The original transaction links could not be verified.")
    normalized = []
    for entry in refs:
        entity = entry.get("EntityRef") if isinstance(entry, dict) else None
        if (not isinstance(entity, dict) or not isinstance(entity.get("type"), str)
                or not isinstance(entity.get("value"), str) or entry.get("IncludeOnSend") is not False
                or (entry.get("Inactive") is not None and entry.get("Inactive") is not False)):
            raise failure("upload_unconfirmed", "Review the original file's transaction links and delivery settings.")
        normalized.append({"EntityRef": {"type": entity["type"], "value": entity["value"]}, "IncludeOnSend": False})
    normalized.sort(key=lambda entry: (entry["EntityRef"]["type"], entry["EntityRef"]["value"]))
    size = remote.get("Size")
    if (any(remote.get(key) != expected[key] for key in ("FileName", "ContentType", "Note"))
            or type(size) not in (int, float) or size != intent["file"]["size"]
            or normalized != expected["AttachableRef"]):
        raise failure("upload_unconfirmed", "The returned file does not match the retained original and destination.")
    return identifier


class DocumentUploads:
    def __init__(self, database, provider_factory, encrypt, decrypt, audit, now=None):
        self.database, self.provider_factory, self.encrypt, self.decrypt, self.audit = database, provider_factory, encrypt, decrypt, audit
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.identity = billing_publications.BillingPublisher(database, provider_factory, encrypt, decrypt, audit, self.now)

    def authorize(self, connection, session_id, intent, *, historical=False):
        actor = self.identity.actor(connection, session_id)
        if actor["role"] != "Admin":
            raise failure("administrator_required", "An active administrator must manage QuickBooks file uploads.", 403)
        company = connection.execute("SELECT company_id FROM company_identity WHERE singleton=1").fetchone()
        if company is None or company[0] != intent["company_id"]:
            raise failure("company_changed", "Open the original business workspace.", 403)
        row = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
        grant = {**dict(row), "grant_fingerprint": grant_fingerprint(row)} if row is not None else None
        matching = grant is not None and grant["realm_id"] == intent["realm_id"] and grant["environment"] == intent["environment"]
        if not historical:
            if not matching:
                raise failure("provider_changed", "Reconnect the original QuickBooks company; the file is retained.")
            if (("grant_fingerprint" in intent.keys() and intent["grant_fingerprint"] != grant["grant_fingerprint"])
                    or ("connection_revision" in intent.keys() and intent["connection_revision"] != billing_assignments.connection_revision(grant["grant_fingerprint"]))):
                raise failure("grant_changed", "The QuickBooks connection changed. Keep this original upload for review.")
        return actor, grant if matching else None

    def record(self, connection, identifier):
        row = connection.execute("SELECT * FROM qbo_document_uploads WHERE id=?", (canonical_uuid(identifier),)).fetchone()
        if row is None:
            raise failure("not_found", "The original file upload was not found.", 404)
        return row

    def alias(self, connection, intent, operation_id):
        row = connection.execute("SELECT * FROM qbo_document_upload_operations WHERE company_id=? AND realm_id=? AND environment=? AND operation_id=?",
                                 (*scope(intent), operation_id)).fetchone()
        if row is not None:
            try:
                if json.loads(self.decrypt(row["payload_ciphertext"]) or "") != [*scope(row), row["operation_id"], row["request_hash"], row["upload_id"]]:
                    raise ValueError()
            except (ValueError, TypeError):
                raise failure("storage_unavailable", "The original upload lookup could not be verified.", 503) from None
        return row

    def save_alias(self, connection, intent, request_hash, identifier):
        values = (*scope(intent), intent["operation_id"], request_hash, identifier)
        connection.execute("INSERT INTO qbo_document_upload_operations VALUES (?,?,?,?,?,?,?)",
                           (*values, self.encrypt(canonical(values))))

    def binding(self, row):
        return [row["id"], *scope(row), row["operation_id"], row["grant_fingerprint"], row["request_hash"],
                row["content_key"], row["actor_email"], row["created_at"]]

    def state_value(self, row):
        return [row["id"], row["revision"], row["state"], row["provider_id"], row["updated_at"]]

    def intent(self, row):
        try:
            value = json.loads(self.decrypt(row["payload_ciphertext"]) or "")
            if (hashlib.sha256(row["payload_ciphertext"].encode()).hexdigest() != row["revision"]
                    or value["binding"] != self.binding(row) or digest(value["intent"]) != row["request_hash"]
                    or row["state"] not in STATES
                    or (row["state"] == "confirmed") != (row["provider_id"] is not None)
                    or json.loads(self.decrypt(row["state_ciphertext"]) or "") != self.state_value(row)):
                raise ValueError()
            return value["intent"]
        except (ValueError, TypeError, KeyError):
            raise failure("storage_unavailable", "The original upload record could not be verified; no replacement was sent.", 503) from None

    def bytes(self, row):
        intent = self.intent(row)
        try:
            value = json.loads(self.decrypt(row["file_ciphertext"]) or "")
            metadata, data = file_content({"filename": intent["file"]["filename"],
                "contentType": intent["file"]["contentType"], "data": value["data"]})
            if value["binding"] != self.binding(row) or metadata != intent["file"]:
                raise ValueError()
            return data
        except (ValueError, TypeError, KeyError, AttemptError):
            raise failure("storage_unavailable", "The retained original file could not be verified; no replacement was sent.", 503) from None

    def public(self, row, grant):
        intent = self.intent(row)
        return {"protocolVersion": 1, "id": row["id"], "companyID": row["company_id"], "realmID": row["realm_id"], "environment": row["environment"],
                "operationID": row["operation_id"], "revision": row["revision"], "state": row["state"],
                "providerID": row["provider_id"], "file": intent["file"], "targets": intent["targets"],
                "jobDocument": intent.get("job_document"),
                "createdAt": row["created_at"], "updatedAt": row["updated_at"],
                "connectionChanged": grant is None or grant["grant_fingerprint"] != row["grant_fingerprint"]}

    def read(self, session_id, identifier, *, include_file=False):
        with self.database() as connection:
            row = self.record(connection, identifier)
            _, grant = self.authorize(connection, session_id, row, historical=True)
            result = self.public(row, grant)
            if include_file:
                result["data"] = base64.b64encode(self.bytes(row)).decode()
            return result

    def lookup(self, session_id, query):
        intent = request_scope(query)
        if set(query) - {"companyID", "realmID", "environment", "operationID", "after"} or {"operationID", "after"} <= set(query):
            raise failure("invalid_query", "Choose the original upload or one recovery page.", 400)
        with self.database() as connection:
            _, grant = self.authorize(connection, session_id, intent, historical=True)
            where, args = "company_id=? AND realm_id=? AND environment=?", list(scope(intent))
            if "operationID" in query:
                alias = self.alias(connection, intent, canonical_uuid(query["operationID"]))
                where += " AND id=?"; args.append(alias["upload_id"] if alias is not None else "")
            if "after" in query:
                where += " AND id>?"; args.append(canonical_uuid(query["after"]))
            rows = connection.execute("SELECT " + METADATA_COLUMNS + " FROM qbo_document_uploads WHERE " + where + " ORDER BY id LIMIT 51", args).fetchall()
            return {"protocolVersion": 1, "maxFileBytes": MAX_FILE_BYTES,
                    "companyID": intent["company_id"], "realmID": intent["realm_id"], "environment": intent["environment"],
                    "connectionRevision": billing_assignments.connection_revision(grant["grant_fingerprint"]) if grant else None,
                    "uploads": [self.public(row, grant) for row in rows[:50]], "nextCursor": rows[49]["id"] if len(rows) > 50 else None}

    def reserve(self, session_id, payload):
        intent, data = validated_request(payload)
        request_hash = digest(intent)
        content_key = digest({key: value for key, value in intent.items() if key not in ("operation_id", "connection_revision", "job_document")})
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, grant = self.authorize(connection, session_id, intent, historical=True)
            alias = self.alias(connection, intent, intent["operation_id"])
            if alias is not None:
                existing = self.record(connection, alias["upload_id"])
                self.authorize(connection, session_id, existing, historical=True)
                if alias["request_hash"] != request_hash or scope(existing) != scope(intent):
                    raise failure("upload_changed", "This upload already owns a different original file or destination.")
                self.bytes(existing)
                return self.public(existing, grant)
            actor, grant = self.authorize(connection, session_id, intent)
            self.verify_job(connection, intent)
            duplicate = connection.execute("SELECT * FROM qbo_document_uploads WHERE company_id=? AND realm_id=? AND environment=? AND content_key=? AND state!='cancelled'",
                (*scope(intent), content_key)).fetchone()
            if duplicate is not None:
                self.bytes(duplicate)
                if self.intent(duplicate).get("job_document") != intent.get("job_document"):
                    raise failure("document_context_changed", "This original file already belongs to another saved document context. Review it without creating a replacement.")
                self.save_alias(connection, intent, request_hash, duplicate["id"])
                return self.public(duplicate, grant)
            now = self.now().isoformat()
            row = {"id": str(uuid.uuid4()), **{key: intent[key] for key in ("company_id", "realm_id", "environment", "operation_id")},
                   "grant_fingerprint": grant["grant_fingerprint"], "request_hash": request_hash, "content_key": content_key,
                   "actor_email": actor["email"], "created_at": now, "updated_at": now, "state": "reserved", "provider_id": None}
            row["payload_ciphertext"] = self.encrypt(canonical({"binding": self.binding(row), "intent": intent}))
            row["file_ciphertext"] = self.encrypt(canonical({"binding": self.binding(row), "data": base64.b64encode(data).decode()}))
            row["revision"] = hashlib.sha256(row["payload_ciphertext"].encode()).hexdigest()
            row["state_ciphertext"] = self.encrypt(canonical(self.state_value(row)))
            columns = list(row)
            connection.execute("INSERT INTO qbo_document_uploads (" + ",".join(columns) + ") VALUES (" + ",".join("?" for _ in columns) + ")", [row[key] for key in columns])
            self.save_alias(connection, intent, request_hash, row["id"])
            self.audit(actor["email"], "reserve", "qbo-document-upload", row["id"], connection=connection)
            return self.public(row, grant)

    def verify_job(self, connection, intent):
        source = intent.get("job_document")
        if source is None:
            return
        customer = connection.execute("SELECT provider_id FROM customer_entity_mappings WHERE company_id=? AND realm_id=? AND environment=? AND local_customer_id=?",
            (*scope(intent), source["localCustomerID"])).fetchone()
        valid = customer is not None and customer[0] == source["customerQuickBooksID"]
        for document in source["documents"]:
            key = (*scope(intent), document["type"], document["localID"])
            mapping = connection.execute("SELECT local_customer_id,provider_id FROM billing_entity_mappings WHERE company_id=? AND realm_id=? AND environment=? AND document_type=? AND local_document_id=?", key).fetchone()
            binding = connection.execute("SELECT service_call_id,local_customer_id FROM billing_job_documents WHERE company_id=? AND realm_id=? AND environment=? AND document_type=? AND local_document_id=?", key).fetchone()
            valid = (valid and mapping is not None and binding is not None
                     and mapping[0] == source["localCustomerID"] and mapping[1] == document["id"]
                     and binding[0] == source["serviceCallID"] and binding[1] == source["localCustomerID"])
        if not valid:
            raise failure("job_document_review", "Review this file's original shared job, customer and billing links. The original file is retained.")

    def check(self, session_id, identifier):
        with self.database() as connection:
            row = self.record(connection, identifier)
            _, grant = self.authorize(connection, session_id, row)
            self.verify_job(connection, self.intent(row))
            if row["state"] == "cancelled":
                raise failure("upload_cancelled", "This never-sent upload was cancelled; its original file is retained.")
            return dict(row), grant

    def transition(self, connection, row, state, actor, provider_id=None):
        updated = {**dict(row), "state": state, "provider_id": provider_id, "updated_at": self.now().isoformat()}
        sealed = self.encrypt(canonical(self.state_value(updated)))
        connection.execute("UPDATE qbo_document_uploads SET state=?,provider_id=?,updated_at=?,state_ciphertext=? WHERE id=?",
                           (state, provider_id, updated["updated_at"], sealed, row["id"]))
        self.audit(actor, state, "qbo-document-upload", row["id"], connection=connection)

    def claim(self, session_id, identifier, revision):
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor, _ = self.authorize(connection, session_id, row)
            self.verify_job(connection, self.intent(row))
            if row["revision"] != revision or row["state"] != "reserved":
                raise failure("upload_pending", "The original upload cannot be sent again. Check its saved status.")
            self.transition(connection, row, "sending", actor["email"])

    def recovery_context(self, connection, session_id, row, expected_grant=None):
        # An explicit recovery may READ the original company through its new
        # grant. This never changes the saved grant or authorizes a replacement
        # upload. Retain this new read context through every provider boundary.
        intent = {key: row[key] for key in ("company_id", "realm_id", "environment")}
        actor, grant = self.authorize(connection, session_id, intent)
        self.verify_job(connection, self.intent(row))
        if expected_grant is not None and grant["grant_fingerprint"] != expected_grant:
            raise failure("grant_changed", "The connection changed during original-file review. Check it again without resending.")
        if row["state"] == "cancelled":
            raise failure("upload_cancelled", "This never-sent upload was cancelled; the file is retained.")
        return actor, grant

    def check_recovery(self, session_id, identifier, expected_grant=None):
        with self.database() as connection:
            row = self.record(connection, identifier)
            _, grant = self.recovery_context(connection, session_id, row, expected_grant)
            return dict(row), grant

    def confirm(self, session_id, identifier, remote, *, recovery_grant=None):
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor, grant = (self.recovery_context(connection, session_id, row, recovery_grant) if recovery_grant is not None
                            else self.authorize(connection, session_id, row))
            self.bytes(row)
            self.verify_job(connection, self.intent(row))
            provider_id = confirmed_attachment(row, self.intent(row), remote)
            if row["state"] == "confirmed" and row["provider_id"] == provider_id:
                return self.public(row, grant)
            if row["state"] not in ("sending", "uncertain"):
                raise failure("upload_unconfirmed", "The original upload has a different saved outcome.")
            self.transition(connection, row, "confirmed", actor["email"], provider_id)
            return self.public(self.record(connection, identifier), grant)

    def retain_uncertain(self, identifier):
        # Internal post-dispatch bookkeeping may run after access is revoked.
        # It never exposes data, adopts another grant, or sends another request.
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            self.intent(row)
            if row["state"] == "sending":
                self.transition(connection, row, "uncertain", "system:qbo-document-recovery")

    @staticmethod
    def verify_targets(provider, intent):
        for target in intent["targets"]:
            remote = provider.read_target(target["type"], target["id"])
            if not isinstance(remote, dict) or remote.get("Id") != target["id"]:
                raise failure("invalid_target", "The selected QuickBooks transaction could not be verified.")
            source = intent.get("job_document")
            customer = remote.get("CustomerRef")
            if source is not None and (not isinstance(customer, dict) or customer.get("value") != source["customerQuickBooksID"]):
                raise failure("job_document_review", "QuickBooks did not confirm this job file's original customer. Review its saved upload status.")

    def send(self, session_id, identifier, revision):
        row, grant = self.check(session_id, identifier)
        if not isinstance(revision, str) or revision != row["revision"]:
            raise failure("upload_changed", "Use the exact original upload revision.")
        if row["state"] == "confirmed":
            return self.public(row, grant)
        if row["state"] != "reserved":
            raise failure("upload_pending", "Check the original upload; an interrupted request is never sent again automatically.")
        intent, data = self.intent(row), self.bytes(row)
        provider = self.provider_factory(grant, lambda: self.check(session_id, identifier))
        self.verify_targets(provider, intent)
        claimed = False
        def claim():
            nonlocal claimed
            self.claim(session_id, identifier, revision)
            claimed = True
        try:
            remote = provider.upload(upload_metadata(row, intent), data, "ga-file-" + row["id"],
                                     claim)
            return self.confirm(session_id, identifier, remote)
        except Exception:
            if claimed:
                self.retain_uncertain(identifier)
            raise

    def recover(self, session_id, identifier):
        row, grant = self.check_recovery(session_id, identifier)
        if row["state"] in ("reserved", "confirmed"):
            return self.public(row, grant)
        intent = self.intent(row)
        fingerprint = grant["grant_fingerprint"]
        provider = self.provider_factory(grant, lambda: self.check_recovery(session_id, identifier, fingerprint))
        if "job_document" in intent:
            self.verify_targets(provider, intent)
        matches = provider.find(marker(row, intent))
        self.check_recovery(session_id, identifier, fingerprint)
        if not isinstance(matches, list) or len(matches) > 1:
            raise failure("upload_unconfirmed", "More than one original-file match needs review; no replacement was sent.")
        if not matches:
            # An empty query is not proof that the original POST did not commit.
            return self.read(session_id, identifier)
        return self.confirm(session_id, identifier, matches[0], recovery_grant=fingerprint)

    def cancel(self, session_id, identifier, revision):
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.record(connection, identifier)
            actor, grant = self.authorize(connection, session_id, row, historical=True)
            self.intent(row)
            if not isinstance(revision, str) or revision != row["revision"] or row["state"] not in ("reserved", "cancelled"):
                raise failure("upload_pending", "Only a never-sent upload can be cancelled. Its original file is retained.")
            if row["state"] == "reserved":
                self.transition(connection, row, "cancelled", actor["email"])
            return self.public(self.record(connection, identifier), grant)
