"""Own-mailbox Google service and immutable, encrypted send operations.

There is deliberately no caller-selected URL, mailbox, token, permanent delete,
or background resend. Recovery reads evidence for the original operation only.
Business-triggered automation requires a separate server-authorized domain intent.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import contextmanager
from datetime import timedelta
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from email.utils import format_datetime, getaddresses

try:
    from . import google_connections as google
except ImportError:  # Direct backend entry point.
    import google_connections as google

ROOT = "https://gmail.googleapis.com/gmail/v1/users/me/"
MAX_FILE_BYTES = 25_000_000
MAX_MESSAGE_BYTES = 48 * 1024 * 1024
MAX_RESPONSE_BYTES = 68 * 1024 * 1024
OFFICE_ROLES = {"Admin", "Dispatcher"}
FOLDERS = {"Inbox": "INBOX", "Sent": "SENT", "All Mail": None, "Trash": "TRASH"}
ACTIONS = {"read": ("modify", [], ["UNREAD"]), "unread": ("modify", ["UNREAD"], []),
           "archive": ("modify", [], ["INBOX"]), "trash": ("trash", [], []), "restore": ("untrash", [], [])}
SCHEMA = """
CREATE TABLE IF NOT EXISTS google_mail_operations (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, actor_email TEXT NOT NULL,
 grant_id TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('action','send')),
 fingerprint TEXT NOT NULL, secrets_ciphertext TEXT NOT NULL, summary_ciphertext TEXT,
 state TEXT NOT NULL CHECK(state IN ('prepared','dispatching','accepted','confirmed','rejected','review','cancelled')),
 provider_id TEXT, provider_thread_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS google_mail_owner ON google_mail_operations(company_id,actor_email,created_at);
"""


def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)
    if "summary_ciphertext" not in {row[1] for row in connection.execute("PRAGMA table_info(google_mail_operations)")}:
        connection.execute("ALTER TABLE google_mail_operations ADD COLUMN summary_ciphertext TEXT")


def failure(code="invalid_mail", status=400):
    messages = {
        "invalid_mail": "Review the original message and attachments before continuing.",
        "mail_access": "This business login does not have access to the mailbox workspace.",
        "mail_changed": "The original mail request or connection changed. Reopen the original request.",
        "mail_unconfirmed": "The mail result is not confirmed. Check the original request; do not send another copy.",
        "mail_rejected": "Google rejected this request. The original message has been retained for review.",
        "mail_not_found": "The original mail request was not found.",
        "mail_limit": "The shared mailbox request limit was reached. Review existing requests before adding more.",
        "mail_business_review": "This message needs a server-approved customer workflow before shared sending is enabled.",
    }
    return google.ConnectionError(code, messages[code], status)


def fields(value, required, optional=()):
    if not isinstance(value, dict) or not set(required) <= set(value) or set(value) - set(required) - set(optional):
        raise failure()
    return value


def text(value, maximum, *, empty=False, lines=False):
    try:
        size = len(value.encode("utf-8")) if isinstance(value, str) else maximum + 1
    except UnicodeError:
        raise failure() from None
    if (not isinstance(value, str) or size > maximum or (not empty and not value) or
            any(ord(c) < 32 and (not lines or c not in "\r\n\t") or ord(c) == 127 for c in value)):
        raise failure()
    return value


def provider_id(value):
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,2048}", value) is None:
        raise failure()
    return value


def decoded(value, maximum):
    if not isinstance(value, str) or len(value) > (maximum + 2) // 3 * 4 or re.fullmatch(r"[A-Za-z0-9_+/=-]*", value) is None:
        raise failure()
    try:
        result = base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True)
    except ValueError:
        raise failure() from None
    if len(result) > maximum:
        raise failure()
    return result


def encoded(value):
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def address(value):
    value = text(value, 254).lower()
    if not re.fullmatch(r"[A-Za-z0-9.!#$%&'*+/=?^_{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}", value):
        raise failure()
    local, domain = value.rsplit("@", 1)
    if local.startswith(".") or local.endswith(".") or ".." in local or any(not label or label.startswith("-") or label.endswith("-") for label in domain.split(".")):
        raise failure()
    return value


def message_id(value):
    if not isinstance(value, str) or len(value) > 250 or not re.fullmatch(r"<[A-Za-z0-9.!#$%&'*+/=?^_{|}~-]+@[A-Za-z0-9.-]+>", value):
        raise failure()
    return value


def transport(method, resource, token, *, query=None, body=None, maximum=MAX_RESPONSE_BYTES):
    """Fixed own-mailbox routes, bounded responses, no redirects and no retries."""
    if (method not in {"GET", "POST"} or not re.fullmatch(
            r"(?:messages(?:/[A-Za-z0-9_-]+(?:/(?:attachments/[A-Za-z0-9_-]+|modify|trash|untrash))?)?|threads/[A-Za-z0-9_-]+)", resource)):
        raise failure()
    url = ROOT + resource + ("?" + urllib.parse.urlencode(query, doseq=True) if query else "")
    request = urllib.request.Request(url, method=method,
        data=google.canonical(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + token, "Accept": "application/json", "Content-Type": "application/json"})
    try:
        with urllib.request.build_opener(google.NoRedirect).open(request, timeout=20) as response:
            if response.status != 200:
                raise failure("mail_unconfirmed", 502)
            data = response.read(maximum + 1)
        if len(data) > maximum:
            raise failure("mail_unconfirmed", 502)
        result = google.strict_json(data)
        if not isinstance(result, dict):
            raise failure("mail_unconfirmed", 502)
        return result
    except urllib.error.HTTPError as error:
        code = error.code
        error.close()
        # Do not let a status from a later GET authorize a repeated send.
        raise failure("mail_rejected" if code in {400, 401, 403, 404, 413, 422} else "mail_unconfirmed", 502) from None
    except (urllib.error.URLError, OSError, ValueError):
        raise failure("mail_unconfirmed", 502) from None


@contextmanager
def provider_response():
    try:
        yield
    except google.ConnectionError as error:
        if error.code != "invalid_mail":
            raise
        raise failure("mail_unconfirmed", 502) from None
    except (ValueError, TypeError, KeyError, AttributeError, RecursionError):
        raise failure("mail_unconfirmed", 502) from None


def project_message(value, *, expected_id=None, expected_thread=None):
    with provider_response():
        return _project_message(value, expected_id=expected_id, expected_thread=expected_thread)


def _project_message(value, *, expected_id=None, expected_thread=None):
    if not isinstance(value, dict):
        raise failure("mail_unconfirmed", 502)
    result = {"id": provider_id(value.get("id")), "threadId": provider_id(value.get("threadId"))}
    if expected_id is not None and result["id"] != expected_id or expected_thread is not None and result["threadId"] != expected_thread:
        raise failure("mail_unconfirmed", 502)
    labels = value.get("labelIds", [])
    if not isinstance(labels, list) or len(labels) > 100 or len(set(map(str, labels))) != len(labels):
        raise failure("mail_unconfirmed", 502)
    result["labelIds"] = [provider_id(label) for label in labels]
    result["snippet"] = text(value.get("snippet", ""), 8192, empty=True, lines=True)
    date = value.get("internalDate")
    if date is not None:
        if not isinstance(date, str) or re.fullmatch(r"[0-9]{1,18}", date) is None:
            raise failure("mail_unconfirmed", 502)
        result["internalDate"] = date
    remaining = [512]
    def part(payload, depth=0):
        remaining[0] -= 1
        if not isinstance(payload, dict) or depth > 20 or remaining[0] < 0:
            raise failure("mail_unconfirmed", 502)
        headers = payload.get("headers", [])
        if not isinstance(headers, list) or len(headers) > 200:
            raise failure("mail_unconfirmed", 502)
        # Return message content, not routing/authentication/debug headers.
        visible = {"from", "to", "cc", "bcc", "reply-to", "date", "subject", "message-id", "references", "in-reply-to", "content-type", "content-disposition", "content-id"}
        clean = []
        for header in headers:
            if not isinstance(header, dict):
                raise failure("mail_unconfirmed", 502)
            name = text(header.get("name"), 200)
            if name.lower() in visible:
                clean.append({"name": name, "value": text(header.get("value"), 65536, empty=True, lines=True)})
        body = payload.get("body", {})
        if not isinstance(body, dict) or type(body.get("size", 0)) is not int or not 0 <= body.get("size", 0) <= MAX_MESSAGE_BYTES:
            raise failure("mail_unconfirmed", 502)
        clean_body = {"size": body.get("size", 0)}
        if "attachmentId" in body:
            clean_body["attachmentId"] = provider_id(body["attachmentId"])
        if "data" in body:
            clean_body["data"] = encoded(decoded(body["data"], MAX_MESSAGE_BYTES))
        children = payload.get("parts", [])
        if not isinstance(children, list) or len(children) > 512:
            raise failure("mail_unconfirmed", 502)
        return {"partId": text(payload.get("partId", ""), 200, empty=True),
            "mimeType": text(payload.get("mimeType", ""), 200, empty=True),
            "filename": text(payload.get("filename", ""), 4096, empty=True),
            "headers": clean, "body": clean_body, "parts": [part(child, depth + 1) for child in children]}
    if value.get("payload") is not None:
        result["payload"] = part(value["payload"])
    return result


class MailContext:
    def __init__(self, service, session, company, grant):
        self.service, self.session = service, session
        self.company, self.grant = google.identifier(company), google.identifier(grant)
        self.owner = None
        self.role = None
        self.deadline = time.monotonic() + 90
        self.check()

    def check(self, connection=None):
        if time.monotonic() > self.deadline:
            raise failure("mail_unconfirmed", 502)
        if connection is None:
            with self.service.google.database() as opened:
                return self.check(opened)
        actor = self.service.google.authorize(connection, self.session, self.company, owner=self.owner)
        if actor["role"] not in OFFICE_ROLES or self.role is not None and actor["role"] != self.role:
            raise failure("mail_access", 403)
        self.service.google.check_grant(self.service.google.grant(connection, self.company, actor["email"]), self.grant, google.FEATURE_SCOPES["mail"])
        self.owner, self.role = actor["email"], actor["role"]
        return actor

    def request(self, method, resource, **kwargs):
        self.check()
        token = self.service.google.access(self.session, self.company, self.grant, google.FEATURE_SCOPES["mail"])
        self.check()
        try:
            result = self.service.transport(method, resource, token, **kwargs)
        except Exception:
            self.check()
            raise
        self.check()
        return result

    def wrap(self, **value):
        self.check()
        return {"companyID": self.company, "actorEmail": self.owner, "grantID": self.grant, **value}


class GoogleMail:
    def __init__(self, connection_service, *, request_transport=None):
        self.google = connection_service
        self.transport = request_transport or transport

    def context(self, session, company, grant):
        return MailContext(self, session, company, grant)

    def page(self, context, *, folder="Inbox", query="", page_token=None, maximum=25):
        if folder not in FOLDERS or type(maximum) is not int or not 1 <= maximum <= 50:
            raise failure()
        query = text(query, 8192, empty=True)
        params = {"maxResults": maximum, "includeSpamTrash": "true" if folder == "Trash" else "false"}
        if FOLDERS[folder]:
            params["labelIds"] = FOLDERS[folder]
        if query:
            params["q"] = query
        if page_token is not None:
            params["pageToken"] = text(page_token, 8192)
        listed = context.request("GET", "messages", query=params, maximum=65536)
        with provider_response():
            references, next_page = listed.get("messages", []), listed.get("nextPageToken")
        if not isinstance(references, list) or len(references) > maximum:
            raise failure("mail_unconfirmed", 502)
        if next_page is not None:
            with provider_response():
                text(next_page, 8192)
            if next_page == page_token:
                raise failure("mail_unconfirmed", 502)
        seen, messages = set(), []
        for reference in references:
            if not isinstance(reference, dict):
                raise failure("mail_unconfirmed", 502)
            with provider_response():
                identifier, thread = provider_id(reference.get("id")), provider_id(reference.get("threadId"))
            if identifier in seen:
                raise failure("mail_unconfirmed", 502)
            seen.add(identifier)
            detail = context.request("GET", "messages/" + identifier, query={"format": "metadata", "metadataHeaders": ["From", "To", "Subject", "Date"]}, maximum=131072)
            messages.append(project_message(detail, expected_id=identifier, expected_thread=thread))
        return context.wrap(messages=messages, nextPageToken=next_page)

    def message(self, context, identifier):
        identifier = provider_id(identifier)
        result = context.request("GET", "messages/" + identifier, query={"format": "full"})
        return context.wrap(message=project_message(result, expected_id=identifier))

    def attachment(self, context, identifier, attachment):
        identifier, attachment = provider_id(identifier), provider_id(attachment)
        message = self.message(context, identifier)["message"]
        def sizes(part):
            return ([part["body"]["size"]] if part["body"].get("attachmentId") == attachment else []) + [size for child in part["parts"] for size in sizes(child)]
        found = sizes(message["payload"]) if "payload" in message else []
        if len(found) != 1 or found[0] > MAX_FILE_BYTES:
            raise failure()
        body = context.request("GET", "messages/" + identifier + "/attachments/" + attachment)
        with provider_response():
            data = decoded(body.get("data"), MAX_FILE_BYTES)
        if type(body.get("size")) is not int or len(data) != body["size"] or len(data) != found[0]:
            raise failure("mail_unconfirmed", 502)
        return context.wrap(messageID=identifier, attachmentID=attachment, body={"data": encoded(data), "size": len(data)})

    def original(self, context, identifier, connection=None):
        if connection is None:
            with self.google.database() as opened:
                return self.original(context, identifier, opened)
        context.check(connection)
        row = connection.execute("SELECT * FROM google_mail_operations WHERE id=?", (google.identifier(identifier),)).fetchone()
        if row is None:
            raise failure("mail_not_found", 404)
        if (row["company_id"], row["actor_email"], row["grant_id"]) != (context.company, context.owner, context.grant):
            raise failure("mail_access", 403)
        return row

    def outcome(self, context, identifier):
        row = self.original(context, identifier)
        return context.wrap(id=row["id"], kind=row["kind"], state=row["state"], messageID=row["provider_id"], threadID=row["provider_thread_id"],
            summary=self.summary(row))

    def summary(self, row):
        if row["kind"] != "send":
            return None
        if row["summary_ciphertext"]:
            return self.google.open("mail-summary", {**dict(row), "secrets_ciphertext": row["summary_ciphertext"]})
        # Additive upgrade: old originals remain readable, never silently cleared.
        with self.google.database() as connection:
            original = connection.execute("SELECT * FROM google_mail_operations WHERE id=?", (row["id"],)).fetchone()
        return self.message_summary(self.google.open("mail-operation", original))

    @staticmethod
    def message_summary(payload):
        return {"to": payload["to"], "subject": payload["subject"], "attachmentNames": [item["name"] for item in payload["attachments"]]}

    def saved_message(self, context, identifier):
        row = self.original(context, identifier)
        if row["kind"] != "send":
            raise failure()
        payload = self.google.open("mail-operation", row)
        return {**self.outcome(context, identifier), "message": payload}

    def prepare(self, context, identifier, kind, payload):
        identifier = google.identifier(identifier)
        clear = google.canonical(payload)
        fingerprint = hmac.new(base64.urlsafe_b64decode(self.google.encryption_key), ("mail\n" + kind + "\n" + clear).encode(), hashlib.sha256).hexdigest()
        with self.google.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            context.check(connection)
            existing = connection.execute("SELECT * FROM google_mail_operations WHERE id=?", (identifier,)).fetchone()
            if existing is not None:
                row = self.original(context, identifier, connection)
                if row["kind"] != kind or not hmac.compare_digest(row["fingerprint"], fingerprint):
                    raise failure("mail_changed", 409)
                # Also verify encrypted original data before claiming idempotency.
                if self.google.open("mail-operation", row) != payload:
                    raise failure("mail_changed", 409)
            else:
                count, size = connection.execute("SELECT COUNT(*),COALESCE(SUM(LENGTH(secrets_ciphertext)),0) FROM google_mail_operations WHERE company_id=? AND actor_email=?",
                    (context.company, context.owner)).fetchone()
                recent = connection.execute("SELECT COUNT(*) FROM google_mail_operations WHERE company_id=? AND actor_email=? AND created_at>?",
                    (context.company, context.owner, (self.google.now() - timedelta(hours=1)).isoformat())).fetchone()[0]
                if count >= 65536 or size + len(clear.encode()) * 2 > 1024 * 1024 * 1024 or recent >= 500:
                    raise failure("mail_limit", 429)
                ciphertext = self.google.seal("mail-operation", context.company, context.owner, identifier, payload)
                summary = self.google.seal("mail-summary", context.company, context.owner, identifier, self.message_summary(payload)) if kind == "send" else None
                now = self.google.now().isoformat()
                connection.execute("INSERT INTO google_mail_operations (id,company_id,actor_email,grant_id,kind,fingerprint,secrets_ciphertext,summary_ciphertext,state,provider_id,provider_thread_id,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,'prepared',NULL,NULL,?,?)",
                    (identifier, context.company, context.owner, context.grant, kind, fingerprint, ciphertext, summary, now, now))
                self.google.audit(context.owner, "prepare", "google-mail-" + kind, identifier, connection=connection)
        return self.outcome(context, identifier)

    def claim(self, context, identifier):
        with self.google.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.original(context, identifier, connection)
            if row["state"] != "prepared":
                return None
            payload = self.google.open("mail-operation", row)
            connection.execute("UPDATE google_mail_operations SET state='dispatching',updated_at=? WHERE id=?", (self.google.now().isoformat(), row["id"]))
            self.google.audit(context.owner, "dispatch", "google-mail-" + row["kind"], row["id"], connection=connection)
        return payload

    def transition(self, context, identifier, state, *, message=None, thread=None, previous=("dispatching", "accepted", "review")):
        with self.google.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = self.original(context, identifier, connection)
            if row["state"] not in previous:
                return
            connection.execute("UPDATE google_mail_operations SET state=?,provider_id=COALESCE(?,provider_id),provider_thread_id=COALESCE(?,provider_thread_id),updated_at=? WHERE id=?",
                (state, message, thread, self.google.now().isoformat(), row["id"]))
            self.google.audit(context.owner, state, "google-mail-" + row["kind"], row["id"], connection=connection)

    def cancel(self, context, identifier):
        self.transition(context, identifier, "cancelled", previous=("prepared",))
        return self.outcome(context, identifier)

    def action(self, context, identifier, *, message, thread, action):
        if action not in ACTIONS:
            raise failure()
        payload = {"messageID": provider_id(message), "threadID": provider_id(thread), "action": action}
        self.prepare(context, identifier, "action", payload)
        claimed = self.claim(context, identifier)
        if claimed is not None:
            endpoint, add, remove = ACTIONS[action]
            try:
                original = self.message(context, message)["message"]
                if original["threadId"] != thread:
                    raise failure("mail_changed", 409)
                context.request("POST", "messages/" + message + "/" + endpoint,
                    body={"addLabelIds": add, "removeLabelIds": remove} if endpoint == "modify" else {})
            except Exception:
                self.transition(context, identifier, "review", previous=("dispatching",))
                raise
        return self.recover_action(context, identifier)

    def recover_action(self, context, identifier):
        row = self.original(context, identifier)
        if row["kind"] != "action":
            raise failure()
        if row["state"] in {"prepared", "cancelled"}:
            return self.outcome(context, identifier)
        payload = self.google.open("mail-operation", row)
        detail = self.message(context, payload["messageID"])["message"]
        labels, action = set(detail["labelIds"]), payload["action"]
        matches = {"read": "UNREAD" not in labels, "unread": "UNREAD" in labels,
            "archive": not labels.intersection({"INBOX", "TRASH"}), "trash": "TRASH" in labels, "restore": "TRASH" not in labels}
        if detail["threadId"] != payload["threadID"] or not matches[action]:
            raise failure("mail_unconfirmed", 409)
        self.transition(context, identifier, "confirmed", message=detail["id"], thread=detail["threadId"])
        return {**self.outcome(context, identifier), "message": detail}

    def prepare_send(self, context, identifier, message):
        """Explicit office composition, not a bypass for automated business sends."""
        if isinstance(message, dict) and set(message).intersection({"business", "workflow", "consent", "customerID", "invoiceID", "jobID"}):
            raise failure("mail_business_review", 403)
        fields(message, ("to", "subject", "body", "attachments"), ("reply",))
        recipients = message["to"]
        if not isinstance(recipients, list) or not 1 <= len(recipients) <= 100:
            raise failure()
        recipients = [address(value) for value in recipients]
        if len(set(recipients)) != len(recipients):
            raise failure()
        payload = {"to": recipients, "subject": text(message["subject"], 900, empty=True),
            "body": text(message["body"], 2 * 1024 * 1024, empty=True, lines=True), "attachments": []}
        attachments = message["attachments"]
        if not isinstance(attachments, list) or len(attachments) > 50:
            raise failure()
        total = 0
        for item in attachments:
            fields(item, ("name", "mimeType", "data"))
            name, mime = text(item["name"], 255), text(item["mimeType"], 200)
            if name in {".", ".."} or "/" in name or "\\" in name or not re.fullmatch(r"[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+", mime):
                raise failure()
            content = decoded(item["data"], MAX_FILE_BYTES)
            total += len(content)
            if total > MAX_FILE_BYTES:
                raise failure()
            payload["attachments"].append({"name": name, "mimeType": mime.lower(), "data": encoded(content)})
        reply = message.get("reply")
        if reply is not None:
            fields(reply, ("parentID", "threadID", "messageID", "subject", "references"))
            if not isinstance(reply["references"], list) or len(reply["references"]) > 50 or reply["subject"] != payload["subject"]:
                raise failure()
            payload["reply"] = {"parentID": provider_id(reply["parentID"]), "threadID": provider_id(reply["threadID"]),
                "messageID": message_id(reply["messageID"]), "subject": payload["subject"],
                "references": [message_id(value) for value in reply["references"]]}
        identifier = google.identifier(identifier)
        # Validate generated MIME size before reserving storage or dispatch.
        self.raw_message(context.owner, identifier, payload, self.google.now())
        return self.prepare(context, identifier, "send", payload)

    @staticmethod
    def raw_message(owner, identifier, payload, created_at):
        message = EmailMessage(policy=policy.SMTP)
        message["From"] = address(owner)
        message["To"] = ", ".join(payload["to"])
        message["Subject"] = payload["subject"]
        message["Message-ID"] = "<gunnaire-" + identifier + "@gunnaire.com>"
        message["Date"] = format_datetime(created_at)
        reply = payload.get("reply")
        if reply:
            message["In-Reply-To"] = reply["messageID"]
            message["References"] = " ".join(dict.fromkeys([*reply["references"], reply["messageID"]]))
        message.set_content(payload["body"], charset="utf-8", cte="base64")
        for item in payload["attachments"]:
            major, minor = item["mimeType"].split("/")
            message.add_attachment(decoded(item["data"], MAX_FILE_BYTES), maintype=major, subtype=minor, filename=item["name"])
        if payload["attachments"]:
            message.set_boundary("gunnaire-" + identifier)
        raw = message.as_bytes()
        if len(raw) > MAX_MESSAGE_BYTES:
            raise failure()
        return raw

    def verify_reply(self, context, payload):
        reply = payload.get("reply")
        if reply is None:
            return
        parent = self.message(context, reply["parentID"])["message"]
        headers = parent.get("payload", {}).get("headers", [])
        def only(name):
            values = [header["value"] for header in headers if header["name"].lower() == name]
            if len(values) != 1:
                raise failure("mail_changed", 409)
            return values[0]
        if parent["threadId"] != reply["threadID"] or only("message-id") != reply["messageID"] or only("subject") != reply["subject"]:
            raise failure("mail_changed", 409)
        original_refs = [header["value"] for header in headers if header["name"].lower() == "references"]
        if len(original_refs) > 1 or (original_refs[0].split() if original_refs else []) != reply["references"]:
            raise failure("mail_changed", 409)

    def send(self, context, identifier):
        row = self.original(context, identifier)
        if row["kind"] != "send":
            raise failure()
        if row["state"] != "prepared":
            return self.outcome(context, identifier)  # Never claim another dispatch.
        payload = self.google.open("mail-operation", row)
        self.verify_reply(context, payload)
        raw = self.raw_message(context.owner, row["id"], payload, google.timestamp(row["created_at"]))
        if self.claim(context, identifier) is None:
            return self.outcome(context, identifier)
        received = False
        try:
            body = {"raw": encoded(raw)}
            if payload.get("reply"):
                body["threadId"] = payload["reply"]["threadID"]
            sent = context.request("POST", "messages/send", body=body, maximum=131072)
            received = True
            with provider_response():
                sent_id, sent_thread = provider_id(sent.get("id")), provider_id(sent.get("threadId"))
            if payload.get("reply") and sent_thread != payload["reply"]["threadID"]:
                raise failure("mail_unconfirmed", 502)
            # Retain accepted identity before the verification GET. Failure of
            # this read or a later audit/save cannot permit another POST.
            self.transition(context, identifier, "accepted", message=sent_id, thread=sent_thread, previous=("dispatching",))
            return self.recover_send(context, identifier)
        except Exception as error:
            rejected = not received and isinstance(error, google.ConnectionError) and error.code == "mail_rejected"
            self.transition(context, identifier, "rejected" if rejected else "review", previous=("dispatching", "accepted"))
            raise

    def recover_send(self, context, identifier):
        row = self.original(context, identifier)
        if row["kind"] != "send":
            raise failure()
        if row["state"] in {"prepared", "rejected", "cancelled", "confirmed"}:
            return self.outcome(context, identifier)
        payload = self.google.open("mail-operation", row)
        expected = self.raw_message(context.owner, row["id"], payload, google.timestamp(row["created_at"]))
        expected_message_id = "<gunnaire-" + row["id"] + "@gunnaire.com>"
        if row["provider_id"]:
            identifier_to_read, expected_thread = row["provider_id"], row["provider_thread_id"]
        else:
            result = context.request("GET", "messages", query={"q": "in:sent rfc822msgid:" + expected_message_id,
                "maxResults": 2, "labelIds": "SENT", "includeSpamTrash": "false"}, maximum=65536)
            with provider_response():
                references = result.get("messages", [])
            if not isinstance(references, list) or len(references) != 1 or result.get("nextPageToken"):
                raise failure("mail_unconfirmed", 409)
            with provider_response():
                identifier_to_read = provider_id(references[0].get("id"))
                expected_thread = provider_id(references[0].get("threadId"))
        result = context.request("GET", "messages/" + identifier_to_read, query={"format": "raw"})
        detail = project_message(result, expected_id=identifier_to_read, expected_thread=expected_thread)
        with provider_response():
            signature = self.mime_signature(decoded(result.get("raw"), MAX_MESSAGE_BYTES))
        if ("SENT" not in detail["labelIds"] or payload.get("reply") and detail["threadId"] != payload["reply"]["threadID"] or
                signature != self.mime_signature(expected)):
            raise failure("mail_unconfirmed", 409)
        self.transition(context, identifier, "confirmed", message=detail["id"], thread=detail["threadId"])
        return self.outcome(context, identifier)

    @staticmethod
    def mime_signature(raw):
        message = BytesParser(policy=policy.default).parsebytes(raw)
        header_names = ("From", "To", "Cc", "Bcc", "Message-ID", "Subject", "In-Reply-To", "References")
        signature = []
        for name in header_names:
            values = message.get_all(name, [])
            if len(values) > 1:
                raise failure("mail_unconfirmed", 409)
            if name in {"From", "To", "Cc", "Bcc"}:
                signature.append(tuple(sorted(address(value) for _, value in getaddresses([str(value) for value in values]))))
            else:
                signature.append(tuple(str(value) for value in values))
        parts = list(message.walk())
        if len(parts) > 100 or any(part.defects for part in parts):
            raise failure("mail_unconfirmed", 409)
        for part in parts:
            if part.is_multipart():
                continue
            content = part.get_payload(decode=True)
            if not isinstance(content, bytes):
                raise failure("mail_unconfirmed", 409)
            if part.get_content_maintype() == "text" and part.get_content_disposition() != "attachment":
                content = content.replace(b"\r\n", b"\n")
            signature.append((part.get_content_type(), part.get_content_charset(), part.get_filename(), part.get_content_disposition(), hashlib.sha256(content).hexdigest()))
        return tuple(signature)

    def outbox(self, context, *, before=None):
        before_date, before_id = None, None
        if before is not None:
            text(before, 4096)
            try:
                # Fernet accepts some noncanonical base64 spellings. A public
                # pagination token must have exactly one representation.
                if base64.urlsafe_b64encode(decoded(before, 4096)).decode() != before:
                    raise failure()
                cursor = self.google.open("mail-cursor", {"id": context.grant, "company_id": context.company,
                    "actor_email": context.owner, "secrets_ciphertext": before})
                fields(cursor, ("createdAt", "id"))
                google.timestamp(cursor["createdAt"])
                before_date, before_id = cursor["createdAt"], google.identifier(cursor["id"])
            except (google.ConnectionError, ValueError, TypeError, KeyError):
                raise failure("mail_changed", 409) from None
        with self.google.database() as connection:
            context.check(connection)
            # Recent mail first; the encrypted cursor is bound to this exact
            # company, mailbox and grant, not a caller-controlled query/offset.
            rows = connection.execute("SELECT id,company_id,actor_email,kind,state,provider_id,provider_thread_id,created_at,summary_ciphertext FROM google_mail_operations WHERE company_id=? AND actor_email=? AND grant_id=? AND kind='send' AND (? IS NULL OR created_at<? OR (created_at=? AND id<?)) ORDER BY created_at DESC,id DESC LIMIT 26",
                (context.company, context.owner, context.grant, before_date, before_date, before_date, before_id)).fetchall()
        next_page = self.google.seal("mail-cursor", context.company, context.owner, context.grant,
            {"createdAt": rows[24]["created_at"], "id": rows[24]["id"]}) if len(rows) > 25 else None
        return context.wrap(operations=[{"id": row["id"], "state": row["state"], "messageID": row["provider_id"], "threadID": row["provider_thread_id"],
            "createdAt": row["created_at"], "summary": self.summary(row)} for row in rows[:25]],
            nextPageToken=next_page)
