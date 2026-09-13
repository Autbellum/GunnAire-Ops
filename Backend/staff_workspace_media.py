"""Authenticated staff media grants for selected operational attachments.

Attachment IDs, unavailable links, and Drive/QBO fields are never capability.
Staff (and Admin) GET `.../content/media` only when the attachment is in the
current selection, full content is prepared, `backendDocumentID` is a non-null
text field, and the company document row still exists. Bytes are served only
via `.../content/media/bytes` after the same checks. Never flips
operationalWorkspaceReady and never invents document defaults.
"""
from __future__ import annotations

from pathlib import Path

try:
    from Backend import staff_workspace_delivery as delivery
    from Backend import qbo_change_capture
    from Backend import document_storage
except ModuleNotFoundError:
    import staff_workspace_delivery as delivery
    import qbo_change_capture
    import document_storage

contract, sharing = delivery.contract, delivery.sharing
SCHEMA = "staff-workspace-operational-media-v2"
QUERY_FIELDS = delivery.SCOPE_FIELDS + " attachmentID"


def document_id(value):
    if not document_storage.header_text(value, 128):
        raise ValueError()
    if "/" in value or "\\" in value or ".." in value:
        raise ValueError()
    return value


def field_text(fields, name, *, required=True):
    value = fields.get(name)
    if value == {"null": {}} or value is None:
        if required:
            raise ValueError()
        return None
    if type(value) is not dict or set(value) != {"text"} or type(value["text"]) is not dict or set(value["text"]) != {"_0"}:
        raise ValueError()
    text = value["text"]["_0"]
    if not document_storage.header_text(text, 4096):
        raise ValueError()
    return text


def field_integer(fields, name):
    value = fields.get(name)
    if type(value) is not dict or set(value) != {"integer"} or type(value["integer"]) is not dict or set(value["integer"]) != {"_0"}:
        raise ValueError()
    number = value["integer"]["_0"]
    if type(number) is not int or not (1 <= number <= 64 * 1024 * 1024):
        raise ValueError()
    return number


class StaffWorkspaceMedia(delivery.StaffWorkspaceDelivery):
    def _resolve(self, connection, session_id, share_id, operation, query):
        contract.exact(query, QUERY_FIELDS)
        attachment_id = sharing.identifier(query["attachmentID"])
        actor, scope, share = self.selection.member_authority(connection, session_id, share_id, query)
        row = connection.execute(
            "SELECT * FROM staff_workspace_selections WHERE id=? AND share_id=?",
            (operation, share_id)).fetchone()
        snapshot = self.selection.shared_original(row, scope, share)
        sequence = self.source.sequence(connection, scope)
        self.selection.receipt(snapshot, sequence)
        if sequence != snapshot["sourceSequence"]:
            raise sharing.fail("source_changed", "Refresh full company data before authorizing attachment media.", 409)
        if not any(record["kind"] == "attachment" and record["id"] == attachment_id for record in snapshot["records"]):
            raise sharing.fail("media_not_selected", "This attachment is not part of the current staff selection.", 404)
        raw = self.original(connection, operation, snapshot)
        if raw is None:
            raise sharing.fail("content_not_prepared", "Prepare the original full content before authorizing media.", 404)
        view = qbo_change_capture.strict_json(raw.decode("utf-8"))
        record = next((item for item in view["records"]
                       if item["kind"] == "attachment" and item["id"] == attachment_id), None)
        if record is None:
            raise sharing.fail("media_not_selected", "This attachment is not part of the prepared operational content.", 404)
        contract.exact(record["body"], "operational")
        contract.exact(record["body"]["operational"], "_0")
        partition = record["body"]["operational"]["_0"]
        contract.exact(partition, "fields unavailableFields structuredFields")
        fields = partition["fields"]
        if type(fields) is not dict:
            raise sharing.fail("media_unavailable", "Attachment media metadata is invalid.", 503)
        # Provider / device paths are never media capability even if present.
        for forbidden in ("googleDriveWebViewLink", "googleDriveFileID", "quickBooksAttachableID", "localFilePath"):
            if forbidden in fields and fields[forbidden] != {"null": {}}:
                raise sharing.fail("media_unavailable", "Provider links are not staff media authority.", 403)
        try:
            backend_document_id = field_text(fields, "backendDocumentID", required=False)
            if backend_document_id is None:
                raise sharing.fail(
                    "media_unavailable",
                    "Attachment media is not prepared for authorized delivery.", 404)
            backend_document_id = document_id(backend_document_id)
            content_type = field_text(fields, "contentType")
            display_name = field_text(fields, "displayName")
            kind_raw = field_text(fields, "kindRaw")
            file_size = field_integer(fields, "fileSizeBytes")
            if not document_storage.header_text(display_name, 255) or "/" in display_name or "\\" in display_name or display_name.startswith("."):
                raise ValueError()
            if not document_storage.content_type(content_type) or not document_storage.header_text(kind_raw, 64):
                raise ValueError()
        except sharing.AttemptError:
            raise
        except (ValueError, TypeError, KeyError):
            raise sharing.fail("media_unavailable", "Attachment media metadata is invalid.", 503) from None
        document = connection.execute("SELECT * FROM documents WHERE id=?", (backend_document_id,)).fetchone()
        if document is None:
            raise sharing.fail("media_unavailable", "Attachment media is not prepared for authorized delivery.", 404)
        if document_storage.financial_document(document) and actor["role"] not in document_storage.BILLING_ROLES:
            raise sharing.fail("media_forbidden", "Financial document access is required for this attachment.", 403)
        try:
            proof = document_storage.content_proof(document)
            if proof["fileSizeBytes"] != file_size or proof["contentType"] != content_type:
                raise document_storage.DocumentReadError(409, "Attachment metadata does not match the original upload.")
        except document_storage.DocumentReadError as error:
            raise sharing.fail("media_unavailable", str(error), error.status) from None
        return actor, dict(
            schema=SCHEMA,
            selectionID=operation,
            sourceSequence=snapshot["sourceSequence"],
            contentSHA256=delivery.digest(raw),
            attachmentID=attachment_id,
            backendDocumentID=backend_document_id,
            contentType=content_type,
            fileSizeBytes=file_size,
            fileSHA256=proof["fileSHA256"],
            displayName=display_name,
            kindRaw=kind_raw,
            operationalWorkspaceReady=False,
            document=document,
        )

    def authorize(self, session_id, share_id, operation, query):
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, grant = self._resolve(connection, session_id, share_id, operation, query)
            self.shares.audit(actor["email"], "authorize-full-media", "staff-workspace-selection", operation,
                              connection=connection)
            return {key: value for key, value in grant.items() if key != "document"}

    def download(self, session_id, share_id, operation, query, *, storage_root: Path):
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, grant = self._resolve(connection, session_id, share_id, operation, query)
            row = grant["document"]
        try:
            data = document_storage.read_document(storage_root, row["stored_path"], expected_bytes=grant["fileSizeBytes"],
                                                  expected_sha256=grant["fileSHA256"])
        except document_storage.DocumentReadError as error:
            raise sharing.fail("media_unavailable", str(error), error.status) from None
        # A slower filesystem read must not outlive source/share revocation or
        # a changed document binding. Check again before releasing any bytes.
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            current_actor, current = self._resolve(connection, session_id, share_id, operation, query)
            if ({key: value for key, value in current.items() if key != "document"}
                    != {key: value for key, value in grant.items() if key != "document"}
                    or dict(current["document"]) != dict(row) or current_actor["email"] != actor["email"]):
                raise sharing.fail("media_unavailable", "Attachment authority changed during download.", 409)
            self.shares.audit(actor["email"], "download-full-media", "staff-workspace-selection", operation,
                              connection=connection)
        return dict(filename=grant["displayName"], contentType=grant["contentType"], data=data,
                    grant={key: value for key, value in grant.items() if key != "document"})
