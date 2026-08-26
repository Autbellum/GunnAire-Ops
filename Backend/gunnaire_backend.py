#!/usr/bin/env python3
"""Small GunnAire Ops backend for shared users, roles, documents, and field payment records."""

from __future__ import annotations

import base64
import hashlib
import html
import json
import os
import re
import secrets
import sqlite3
import urllib.error
import urllib.parse
import urllib.request
import uuid
import threading
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse


HOST = os.environ.get("GUNNAIRE_BACKEND_HOST", "0.0.0.0")
SERVICE_VERSION = "2026.08.26.2"
# Managed hosts such as Render supply PORT. Keep the GunnAire setting first so
# local/LAN deployments remain deterministic.
PORT = int(os.environ.get("GUNNAIRE_BACKEND_PORT", os.environ.get("PORT", "8787")))
API_TOKEN = os.environ.get("GUNNAIRE_BACKEND_API_TOKEN", "")
AUTH_MODE = os.environ.get("GUNNAIRE_BACKEND_AUTH_MODE", "api-token").strip().lower()
PRIMARY_ADMIN_EMAIL = os.environ.get("GUNNAIRE_PRIMARY_ADMIN_EMAIL", "eric.gunn@gunnaire.com").strip().lower()
GOOGLE_CLIENT_ID = os.environ.get("GUNNAIRE_GOOGLE_CLIENT_ID", "").strip()
GOOGLE_ALLOWED_DOMAIN = os.environ.get("GUNNAIRE_GOOGLE_ALLOWED_DOMAIN", "gunnaire.com").strip().lower()
DATA_ROOT_RAW = os.environ.get("GUNNAIRE_BACKEND_DATA_DIR", "").strip()
DATA_ROOT = Path(DATA_ROOT_RAW).expanduser() if DATA_ROOT_RAW else None
DB_PATH = Path(
    os.environ.get(
        "GUNNAIRE_BACKEND_DB",
        str(DATA_ROOT / "gunnaire_backend.sqlite3") if DATA_ROOT else "gunnaire_backend.sqlite3",
    )
).expanduser()
STORAGE_ROOT = Path(
    os.environ.get(
        "GUNNAIRE_BACKEND_STORAGE",
        str(DATA_ROOT / "storage") if DATA_ROOT else "storage",
    )
).expanduser()
QBO_CLIENT_ID = os.environ.get("GUNNAIRE_QBO_CLIENT_ID", "").strip()
QBO_CLIENT_SECRET = os.environ.get("GUNNAIRE_QBO_CLIENT_SECRET", "").strip()
QBO_REDIRECT_URI = os.environ.get("GUNNAIRE_QBO_REDIRECT_URI", "").strip()
QBO_ENVIRONMENT = os.environ.get("GUNNAIRE_QBO_ENVIRONMENT", "sandbox").strip().lower()
# A valid Fernet key is required before the confidential bridge persists a
# rotating QBO refresh token. This deliberately fails closed instead of
# downgrading production credentials to plaintext SQLite storage.
QBO_TOKEN_ENCRYPTION_KEY = os.environ.get("GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY", "").strip()
QBO_TOKEN_ENDPOINT = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer"
QBO_REVOCATION_ENDPOINT = "https://developer.api.intuit.com/v2/oauth2/tokens/revoke"
PUBLIC_BOOKING_ENABLED = os.environ.get("GUNNAIRE_PUBLIC_BOOKING_ENABLED", "false").strip().lower() == "true"
PUBLIC_BOOKING_RATE_LIMIT = int(os.environ.get("GUNNAIRE_PUBLIC_BOOKING_RATE_LIMIT", "5"))
PUBLIC_BOOKING_RATE_WINDOW_SECONDS = int(os.environ.get("GUNNAIRE_PUBLIC_BOOKING_RATE_WINDOW_SECONDS", "3600"))
PUBLIC_BOOKING_ATTEMPTS: dict[str, list[float]] = {}
PUBLIC_BOOKING_LOCK = threading.Lock()
CUSTOMER_PORTAL_ENABLED = os.environ.get("GUNNAIRE_CUSTOMER_PORTAL_ENABLED", "false").strip().lower() == "true"
CUSTOMER_PORTAL_BASE_URL = os.environ.get("GUNNAIRE_CUSTOMER_PORTAL_BASE_URL", "").strip().rstrip("/")
CUSTOMER_PORTAL_MAX_DAYS = min(max(int(os.environ.get("GUNNAIRE_CUSTOMER_PORTAL_MAX_DAYS", "30")), 1), 90)
MAX_DOCUMENT_BYTES = min(max(int(os.environ.get("GUNNAIRE_MAX_DOCUMENT_BYTES", str(12 * 1024 * 1024))), 1024), 25 * 1024 * 1024)
ALLOWED_CORS_ORIGINS = {
    origin.strip().rstrip("/")
    for origin in os.environ.get("GUNNAIRE_ALLOWED_CORS_ORIGINS", "").split(",")
    if origin.strip()
}

if AUTH_MODE not in {"api-token", "google-id-token"}:
    raise RuntimeError("GUNNAIRE_BACKEND_AUTH_MODE must be api-token or google-id-token")

if QBO_ENVIRONMENT not in {"sandbox", "production"}:
    raise RuntimeError("GUNNAIRE_QBO_ENVIRONMENT must be sandbox or production")

if AUTH_MODE == "google-id-token":
    try:
        from google.auth.transport import requests as google_requests
        from google.oauth2 import id_token as google_id_token
    except ImportError as error:
        raise RuntimeError(
            "google-id-token mode requires google-auth; install Backend/requirements.txt"
        ) from error
    if not GOOGLE_CLIENT_ID:
        raise RuntimeError("GUNNAIRE_GOOGLE_CLIENT_ID is required in google-id-token mode")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def normalize_email(value: str | None) -> str:
    return (value or "").strip().lower()


def safe_filename(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._ -]", "_", value.strip())
    return cleaned or "upload.bin"


def portal_token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def portal_url(token: str) -> str | None:
    if not CUSTOMER_PORTAL_BASE_URL.startswith("https://"):
        return None
    return f"{CUSTOMER_PORTAL_BASE_URL}/portal/{token}"


def qbo_is_configured() -> bool:
    return bool(QBO_CLIENT_ID and QBO_CLIENT_SECRET and QBO_REDIRECT_URI)


def qbo_token_store() -> object | None:
    """Return the configured encryptor without ever logging its key or plaintext."""
    if not QBO_TOKEN_ENCRYPTION_KEY:
        return None
    try:
        from cryptography.fernet import Fernet
        return Fernet(QBO_TOKEN_ENCRYPTION_KEY.encode("utf-8"))
    except (ImportError, ValueError):
        return None


def qbo_token_storage_is_configured() -> bool:
    return qbo_token_store() is not None


def encrypt_qbo_refresh_token(token: str) -> str:
    encryptor = qbo_token_store()
    if encryptor is None:
        raise RuntimeError("QuickBooks token encryption is not configured")
    return encryptor.encrypt(token.encode("utf-8")).decode("utf-8")


def decrypt_qbo_refresh_token(ciphertext: str) -> str | None:
    encryptor = qbo_token_store()
    if encryptor is None:
        return None
    try:
        return encryptor.decrypt(ciphertext.encode("utf-8")).decode("utf-8")
    except Exception:
        return None


def qbo_request(form: dict[str, str], endpoint: str) -> tuple[int, dict[str, object]]:
    """Confidential QBO call. Never log the body because it can contain OAuth tokens."""
    if not qbo_is_configured():
        return HTTPStatus.SERVICE_UNAVAILABLE, {"error": "QuickBooks bridge is not configured"}
    basic = base64.b64encode(f"{QBO_CLIENT_ID}:{QBO_CLIENT_SECRET}".encode("utf-8")).decode("ascii")
    request = urllib.request.Request(
        endpoint,
        data=urllib.parse.urlencode(form).encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Basic {basic}",
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            payload = json.loads(raw.decode("utf-8")) if raw else {}
            return response.status, payload if isinstance(payload, dict) else {}
    except urllib.error.HTTPError as error:
        # Do not expose Intuit's raw OAuth diagnostics; they may include sensitive context.
        return error.code, {"error": "QuickBooks rejected the OAuth request", "status": error.code}
    except (urllib.error.URLError, TimeoutError):
        return HTTPStatus.BAD_GATEWAY, {"error": "QuickBooks is unavailable"}


def qbo_token_response(payload: dict[str, object]) -> dict[str, object] | None:
    access_token = payload.get("access_token")
    refresh_token = payload.get("refresh_token")
    expires_in = payload.get("expires_in")
    if not isinstance(access_token, str) or not isinstance(refresh_token, str):
        return None
    if not isinstance(expires_in, (int, float)):
        return None
    return {"accessToken": access_token, "refreshToken": refresh_token, "expiresIn": expires_in}


def qbo_client_token_response(payload: dict[str, object]) -> dict[str, object] | None:
    """Return only the short-lived access credential to an authenticated app."""
    token_response = qbo_token_response(payload)
    if token_response is None:
        return None
    return {
        "accessToken": token_response["accessToken"],
        "expiresIn": token_response["expiresIn"],
    }


def qbo_connection_matches(row: sqlite3.Row, realm_id: str, environment: str) -> bool:
    """Bind every access-token refresh to the same company and Intuit environment."""
    return row["realm_id"] == realm_id and row["environment"] == environment


def db() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(DB_PATH)
    connection.row_factory = sqlite3.Row
    return connection


def ensure_column(connection: sqlite3.Connection, table: str, column: str, definition: str) -> None:
    """Forward-compatible SQLite migration for additive metadata columns."""
    existing = {row["name"] for row in connection.execute(f"PRAGMA table_info({table})")}
    if column not in existing:
        connection.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")


def initialize_database() -> None:
    with db() as connection:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                email TEXT PRIMARY KEY,
                role TEXT NOT NULL,
                is_active INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS public_service_requests (
                id TEXT PRIMARY KEY,
                customer_name TEXT NOT NULL,
                phone TEXT,
                email TEXT,
                address TEXT,
                requested_service_type TEXT NOT NULL,
                urgency TEXT NOT NULL,
                summary TEXT NOT NULL,
                preferred_date TEXT,
                created_at TEXT NOT NULL,
                claimed_at TEXT,
                claimed_by TEXT
            )
            """
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS documents (
                id TEXT PRIMARY KEY,
                filename TEXT NOT NULL,
                content_type TEXT NOT NULL,
                kind TEXT NOT NULL,
                service_call_id TEXT,
                invoice_id TEXT,
                estimate_id TEXT,
                customer_equipment_id TEXT,
                equipment_name TEXT,
                customer_name TEXT,
                stored_path TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """
        )
        ensure_column(connection, "documents", "invoice_id", "TEXT")
        ensure_column(connection, "documents", "estimate_id", "TEXT")
        ensure_column(connection, "documents", "customer_equipment_id", "TEXT")
        ensure_column(connection, "documents", "equipment_name", "TEXT")
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS payment_collections (
                id TEXT PRIMARY KEY,
                payment_id TEXT NOT NULL UNIQUE,
                invoice_id TEXT,
                invoice_quickbooks_id TEXT,
                customer_name TEXT NOT NULL,
                customer_email TEXT,
                amount REAL NOT NULL,
                method TEXT NOT NULL,
                card_last4 TEXT,
                authorization_reference TEXT,
                processor TEXT,
                notes TEXT,
                collected_by TEXT,
                collected_at TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS field_payment_assignments (
                id TEXT PRIMARY KEY,
                invoice_id TEXT NOT NULL,
                customer_name TEXT NOT NULL,
                amount REAL NOT NULL,
                assigned_to TEXT NOT NULL,
                assigned_by TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                accepted_at TEXT,
                cancelled_at TEXT,
                cancelled_by TEXT
            )
            """
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS customer_communications (
                id TEXT PRIMARY KEY,
                customer_name TEXT NOT NULL,
                customer_email TEXT,
                service_call_id TEXT,
                invoice_id TEXT,
                estimate_id TEXT,
                channel TEXT NOT NULL,
                direction TEXT NOT NULL,
                recipient TEXT NOT NULL,
                subject TEXT NOT NULL,
                delivery_status TEXT NOT NULL,
                attachment_file_names_json TEXT,
                provider_message_id TEXT,
                occurred_at TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS audit_events (
                id TEXT PRIMARY KEY,
                occurred_at TEXT NOT NULL,
                actor_email TEXT NOT NULL,
                action TEXT NOT NULL,
                subject_type TEXT NOT NULL,
                subject_id TEXT,
                metadata_json TEXT NOT NULL DEFAULT '{}'
            )
            """
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS customer_portal_links (
                id TEXT PRIMARY KEY,
                token_hash TEXT NOT NULL UNIQUE,
                customer_name TEXT NOT NULL,
                customer_email TEXT NOT NULL,
                service_call_id TEXT,
                invoice_id TEXT,
                title TEXT NOT NULL,
                appointment_summary TEXT,
                invoice_reference TEXT,
                balance_due REAL,
                expires_at TEXT NOT NULL,
                revoked_at TEXT,
                created_at TEXT NOT NULL,
                created_by TEXT NOT NULL
            )
            """
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS qbo_connections (
                id INTEGER PRIMARY KEY CHECK(id = 1),
                realm_id TEXT NOT NULL,
                refresh_token_ciphertext TEXT NOT NULL,
                environment TEXT NOT NULL,
                client_id_fingerprint TEXT NOT NULL,
                authorized_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        now = utc_now()
        connection.execute(
            """
            INSERT INTO users(email, role, is_active, created_at, updated_at)
            VALUES (?, 'Admin', 1, ?, ?)
            ON CONFLICT(email) DO UPDATE SET role = 'Admin', is_active = 1, updated_at = excluded.updated_at
            """,
            (PRIMARY_ADMIN_EMAIL, now, now),
        )


def user_record(row: sqlite3.Row) -> dict[str, object]:
    return {
        "email": row["email"],
        "role": row["role"],
        "isActive": bool(row["is_active"]),
        "createdAt": row["created_at"],
    }


def payment_collection_record(row: sqlite3.Row) -> dict[str, object]:
    return {
        "id": row["id"],
        "paymentID": row["payment_id"],
        "invoiceID": row["invoice_id"],
        "invoiceQuickBooksID": row["invoice_quickbooks_id"],
        "customerName": row["customer_name"],
        "customerEmail": row["customer_email"],
        "amount": row["amount"],
        "method": row["method"],
        "cardLast4": row["card_last4"],
        "authorizationReference": row["authorization_reference"],
        "processor": row["processor"],
        "notes": row["notes"],
        "collectedBy": row["collected_by"],
        "collectedAt": row["collected_at"],
        "createdAt": row["created_at"],
    }


def field_payment_assignment_record(row: sqlite3.Row) -> dict[str, object]:
    return {
        "id": row["id"],
        "invoiceID": row["invoice_id"],
        "customerName": row["customer_name"],
        "amount": row["amount"],
        "assignedTo": row["assigned_to"],
        "assignedBy": row["assigned_by"],
        "status": row["status"],
        "createdAt": row["created_at"],
        "acceptedAt": row["accepted_at"],
        "cancelledAt": row["cancelled_at"],
    }


def document_record(row: sqlite3.Row) -> dict[str, object]:
    return {
        "id": row["id"],
        "filename": row["filename"],
        "contentType": row["content_type"],
        "kind": row["kind"],
        "serviceCallID": row["service_call_id"],
        "invoiceID": row["invoice_id"],
        "estimateID": row["estimate_id"],
        "customerEquipmentID": row["customer_equipment_id"],
        "equipmentName": row["equipment_name"],
        "customerName": row["customer_name"],
        "createdAt": row["created_at"],
    }


def document_contains_financial_data(row: sqlite3.Row) -> bool:
    """Classify records that can expose billing or payment data.

    Files created in the field remain available to active staff, while invoice,
    estimate, payment, receipt, and bill artifacts are restricted to the roles
    that are allowed to handle billing documents. Checking both the stored kind
    and the billing references protects older uploads whose kind predates the
    current document taxonomy.
    """
    financial_kinds = {
        "invoice", "estimate", "payment", "receipt", "bill", "financial",
        "credit", "statement", "transaction",
    }
    kind = str(row["kind"] or "").strip().lower()
    return bool(row["invoice_id"] or row["estimate_id"] or kind in financial_kinds)


def communication_record(row: sqlite3.Row) -> dict[str, object]:
    return {
        "id": row["id"],
        "customerName": row["customer_name"],
        "customerEmail": row["customer_email"],
        "serviceCallID": row["service_call_id"],
        "invoiceID": row["invoice_id"],
        "estimateID": row["estimate_id"],
        "channel": row["channel"],
        "direction": row["direction"],
        "recipient": row["recipient"],
        "subject": row["subject"],
        "deliveryStatus": row["delivery_status"],
        "attachmentFileNames": json.loads(row["attachment_file_names_json"] or "[]"),
        "providerMessageID": row["provider_message_id"],
        "occurredAt": row["occurred_at"],
        "createdAt": row["created_at"],
    }


def customer_portal_link_record(row: sqlite3.Row) -> dict[str, object]:
    """Return management metadata only; the token hash and capability URL never leave storage."""
    return {
        "id": row["id"],
        "customerName": row["customer_name"],
        "customerEmail": row["customer_email"],
        "serviceCallID": row["service_call_id"],
        "invoiceID": row["invoice_id"],
        "title": row["title"],
        "appointmentSummary": row["appointment_summary"],
        "invoiceReference": row["invoice_reference"],
        "balanceDue": row["balance_due"],
        "expiresAt": row["expires_at"],
        "revokedAt": row["revoked_at"],
        "createdAt": row["created_at"],
        "createdBy": row["created_by"],
    }


def public_service_request_record(row: sqlite3.Row) -> dict[str, object]:
    return {
        "id": row["id"], "customerName": row["customer_name"], "phone": row["phone"],
        "email": row["email"], "address": row["address"],
        "requestedServiceType": row["requested_service_type"], "urgency": row["urgency"],
        "summary": row["summary"], "preferredDate": row["preferred_date"],
        "createdAt": row["created_at"],
    }


def audit_event_record(row: sqlite3.Row) -> dict[str, object]:
    return {
        "id": row["id"],
        "occurredAt": row["occurred_at"],
        "actorEmail": row["actor_email"],
        "action": row["action"],
        "subjectType": row["subject_type"],
        "subjectID": row["subject_id"],
    }


def record_audit_event(actor_email: str | None, action: str, subject_type: str, subject_id: str | None = None) -> None:
    """Record high-impact actions without storing tokens, payment details, or customer content."""
    actor = normalize_email(actor_email)
    if not actor:
        return
    with db() as connection:
        connection.execute(
            """
            INSERT INTO audit_events(id, occurred_at, actor_email, action, subject_type, subject_id)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (str(uuid.uuid4()), utc_now(), actor, action, subject_type, subject_id),
        )


class GunnAireBackendHandler(BaseHTTPRequestHandler):
    server_version = f"GunnAireBackend/{SERVICE_VERSION}"

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_cors_headers()
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self.write_json(
                {"status": "ok", "serviceVersion": SERVICE_VERSION, "time": utc_now()},
                status=HTTPStatus.OK,
                require_auth=False,
            )
            return
        if parsed.path.startswith("/portal/"):
            self.render_customer_portal(unquote(parsed.path.removeprefix("/portal/")).strip())
            return
        if self.principal() is None:
            self.write_json({"error": "Unauthorized"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        if parsed.path == "/api/session":
            self.write_json({"user": self.principal()})
            return
        if parsed.path == "/api/users":
            if not self.require_admin():
                return
            with db() as connection:
                rows = connection.execute("SELECT * FROM users ORDER BY email").fetchall()
            self.write_json({"users": [user_record(row) for row in rows]})
            return
        if parsed.path == "/api/audit-events":
            if not self.require_admin():
                return
            with db() as connection:
                rows = connection.execute(
                    "SELECT * FROM audit_events ORDER BY occurred_at DESC LIMIT 200"
                ).fetchall()
            self.write_json({"events": [audit_event_record(row) for row in rows]})
            return
        if parsed.path == "/api/customer-portal-links":
            if not self.require_admin():
                return
            with db() as connection:
                rows = connection.execute(
                    "SELECT * FROM customer_portal_links ORDER BY created_at DESC LIMIT 200"
                ).fetchall()
            self.write_json({"links": [customer_portal_link_record(row) for row in rows]})
            return
        if parsed.path == "/api/payments":
            if not self.require_financial_access():
                return
            with db() as connection:
                rows = connection.execute(
                    "SELECT * FROM payment_collections ORDER BY collected_at DESC, created_at DESC LIMIT 500"
                ).fetchall()
            self.write_json({"payments": [payment_collection_record(row) for row in rows]})
            return
        if parsed.path == "/api/field-payment-assignments":
            if not self.require_field_payment_assignment_access():
                return
            principal = self.principal() or {}
            role = principal.get("role")
            with db() as connection:
                if role == "Field Technician":
                    rows = connection.execute(
                        """
                        SELECT * FROM field_payment_assignments
                        WHERE assigned_to = ? AND status IN ('pending', 'accepted')
                        ORDER BY created_at DESC LIMIT 200
                        """,
                        (principal.get("email"),),
                    ).fetchall()
                else:
                    rows = connection.execute(
                        "SELECT * FROM field_payment_assignments ORDER BY created_at DESC LIMIT 500"
                    ).fetchall()
            self.write_json({"assignments": [field_payment_assignment_record(row) for row in rows]})
            return
        if parsed.path == "/api/documents":
            with db() as connection:
                rows = connection.execute(
                    "SELECT * FROM documents ORDER BY created_at DESC LIMIT 500"
                ).fetchall()
            if not self.has_billing_document_access():
                rows = [row for row in rows if not document_contains_financial_data(row)]
            self.write_json({"documents": [document_record(row) for row in rows]})
            return
        if parsed.path == "/api/communications":
            if not self.require_admin():
                return
            with db() as connection:
                rows = connection.execute(
                    "SELECT * FROM customer_communications ORDER BY occurred_at DESC, created_at DESC LIMIT 500"
                ).fetchall()
            self.write_json({"communications": [communication_record(row) for row in rows]})
            return
        if parsed.path == "/api/service-requests":
            if not self.require_dispatch_access():
                return
            with db() as connection:
                rows = connection.execute(
                    "SELECT * FROM public_service_requests WHERE claimed_at IS NULL ORDER BY created_at ASC LIMIT 500"
                ).fetchall()
            self.write_json({"serviceRequests": [public_service_request_record(row) for row in rows]})
            return
        if parsed.path.startswith("/api/documents/") and parsed.path.endswith("/download"):
            document_id = unquote(parsed.path.removeprefix("/api/documents/").removesuffix("/download")).strip()
            self.download_document(document_id)
            return
        self.write_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/public/service-requests":
            self.store_public_service_request()
            return
        if self.principal() is None:
            self.write_json({"error": "Unauthorized"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        if parsed.path == "/api/users":
            if not self.require_admin():
                return
            self.upsert_user()
            return
        if parsed.path == "/api/documents":
            self.store_document()
            return
        if parsed.path == "/api/payments":
            if not self.require_payment_collector():
                return
            self.store_payment_collection()
            return
        if parsed.path == "/api/field-payment-assignments":
            if not self.require_field_payment_assignment_management():
                return
            self.create_field_payment_assignment()
            return
        if parsed.path.startswith("/api/field-payment-assignments/") and parsed.path.endswith("/accept"):
            if not self.require_field_payment_assignment_access():
                return
            assignment_id = unquote(parsed.path.removeprefix("/api/field-payment-assignments/").removesuffix("/accept")).strip()
            self.accept_field_payment_assignment(assignment_id)
            return
        if parsed.path == "/api/communications":
            if not self.require_admin():
                return
            self.store_customer_communication()
            return
        if parsed.path == "/api/customer-portal-links":
            if not self.require_admin():
                return
            self.create_customer_portal_link()
            return
        if parsed.path.startswith("/api/service-requests/") and parsed.path.endswith("/claim"):
            if not self.require_dispatch_access():
                return
            request_id = unquote(parsed.path.removeprefix("/api/service-requests/").removesuffix("/claim")).strip()
            self.claim_public_service_request(request_id)
            return
        if parsed.path == "/api/qbo/exchange":
            if not self.require_admin():
                return
            self.exchange_qbo_authorization_code()
            return
        if parsed.path == "/api/qbo/refresh":
            if not self.require_admin():
                return
            self.refresh_qbo_access_token()
            return
        if parsed.path == "/api/qbo/revoke":
            if not self.require_admin():
                return
            self.revoke_qbo_token()
            return
        self.write_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def do_DELETE(self) -> None:
        parsed = urlparse(self.path)
        if self.principal() is None:
            self.write_json({"error": "Unauthorized"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        if parsed.path.startswith("/api/users/"):
            if not self.require_admin():
                return
            email = normalize_email(unquote(parsed.path.removeprefix("/api/users/")))
            if not email:
                self.write_json({"error": "Missing email"}, status=HTTPStatus.BAD_REQUEST)
                return
            if email == PRIMARY_ADMIN_EMAIL:
                self.write_json({"error": "Primary admin cannot be deactivated"}, status=HTTPStatus.BAD_REQUEST)
                return
            now = utc_now()
            with db() as connection:
                connection.execute(
                    "UPDATE users SET is_active = 0, updated_at = ? WHERE email = ?",
                    (now, email),
                )
            principal = self.principal() or {}
            record_audit_event(principal.get("email") if isinstance(principal.get("email"), str) else None, "deactivate", "user", email)
            self.write_json({"email": email, "isActive": False})
            return
        if parsed.path.startswith("/api/customer-portal-links/"):
            if not self.require_admin():
                return
            link_id = unquote(parsed.path.removeprefix("/api/customer-portal-links/")).strip()
            if not re.fullmatch(r"[0-9a-fA-F-]{36}", link_id):
                self.write_json({"error": "Invalid portal link"}, status=HTTPStatus.BAD_REQUEST)
                return
            with db() as connection:
                updated = connection.execute(
                    "UPDATE customer_portal_links SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
                    (utc_now(), link_id),
                ).rowcount
            if updated == 0:
                self.write_json({"error": "Portal link not found or already revoked"}, status=HTTPStatus.NOT_FOUND)
                return
            principal = self.principal() or {}
            record_audit_event(principal.get("email") if isinstance(principal.get("email"), str) else None, "revoke", "customer-portal-link", link_id)
            self.write_json({"id": link_id, "revoked": True})
            return
        if parsed.path.startswith("/api/field-payment-assignments/"):
            if not self.require_field_payment_assignment_management():
                return
            assignment_id = unquote(parsed.path.removeprefix("/api/field-payment-assignments/")).strip()
            self.cancel_field_payment_assignment(assignment_id)
            return
        self.write_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def principal(self) -> dict[str, object] | None:
        cached = getattr(self, "_principal", None)
        if cached is not None:
            return cached
        if getattr(self, "_principal_checked", False):
            return None
        self._principal_checked = True

        if AUTH_MODE == "api-token":
            if not API_TOKEN or self.headers.get("Authorization") != f"Bearer {API_TOKEN}":
                return None
            # Compatibility mode for a physically controlled development/LAN server only.
            self._principal = {
                "email": PRIMARY_ADMIN_EMAIL,
                "role": "Admin",
                "isActive": True,
                "createdAt": None,
            }
            return self._principal

        token = self.headers.get("X-GunnAire-Google-ID-Token", "").strip()
        if not token:
            return None
        try:
            claims = google_id_token.verify_oauth2_token(token, google_requests.Request(), GOOGLE_CLIENT_ID)
        except Exception:
            return None
        email = normalize_email(claims.get("email") if isinstance(claims.get("email"), str) else None)
        hosted_domain = normalize_email(claims.get("hd") if isinstance(claims.get("hd"), str) else None)
        if not email or not bool(claims.get("email_verified")) or hosted_domain != GOOGLE_ALLOWED_DOMAIN:
            return None
        with db() as connection:
            row = connection.execute("SELECT * FROM users WHERE email = ?", (email,)).fetchone()
        if row is None or not bool(row["is_active"]):
            return None
        self._principal = user_record(row)
        return self._principal

    def require_admin(self) -> bool:
        principal = self.principal()
        if principal is not None and principal.get("role") == "Admin":
            return True
        self.write_json({"error": "Administrator access required"}, status=HTTPStatus.FORBIDDEN, require_auth=False)
        return False

    def require_payment_collector(self) -> bool:
        principal = self.principal()
        if principal is not None and principal.get("role") in {"Admin", "Field Technician"}:
            return True
        self.write_json({"error": "Field payment access required"}, status=HTTPStatus.FORBIDDEN, require_auth=False)
        return False

    def require_financial_access(self) -> bool:
        principal = self.principal()
        if principal is not None and principal.get("role") in {"Admin", "Accounting"}:
            return True
        self.write_json({"error": "Financial access required"}, status=HTTPStatus.FORBIDDEN, require_auth=False)
        return False

    def has_billing_document_access(self) -> bool:
        principal = self.principal()
        return principal is not None and principal.get("role") in {
            "Admin", "Accounting", "Field Technician",
        }

    def require_dispatch_access(self) -> bool:
        principal = self.principal()
        if principal is not None and principal.get("role") in {"Admin", "Dispatcher"}:
            return True
        self.write_json({"error": "Dispatcher access required"}, status=HTTPStatus.FORBIDDEN, require_auth=False)
        return False

    def require_field_payment_assignment_access(self) -> bool:
        principal = self.principal()
        if principal is not None and principal.get("role") in {
            "Admin", "Accounting", "Dispatcher", "Field Technician",
        }:
            return True
        self.write_json({"error": "Field collection assignment access required"}, status=HTTPStatus.FORBIDDEN, require_auth=False)
        return False

    def require_field_payment_assignment_management(self) -> bool:
        principal = self.principal()
        if principal is not None and principal.get("role") in {"Admin", "Accounting", "Dispatcher"}:
            return True
        self.write_json({"error": "Field collection assignment management access required"}, status=HTTPStatus.FORBIDDEN, require_auth=False)
        return False

    def read_json(self) -> dict[str, object]:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        data = self.rfile.read(length)
        return json.loads(data.decode("utf-8"))

    def create_customer_portal_link(self) -> None:
        if not CUSTOMER_PORTAL_ENABLED or portal_url("test") is None:
            self.write_json({"error": "Customer portal is not configured for HTTPS"}, status=HTTPStatus.SERVICE_UNAVAILABLE)
            return
        try:
            payload = self.read_json()
        except json.JSONDecodeError:
            self.write_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return
        customer_name = str(payload.get("customerName") or "").strip()
        customer_email = normalize_email(payload.get("customerEmail") if isinstance(payload.get("customerEmail"), str) else None)
        service_call_id = str(payload.get("serviceCallID") or "").strip() or None
        invoice_id = str(payload.get("invoiceID") or "").strip() or None
        title = str(payload.get("title") or "GunnAire service update").strip()
        appointment_summary = str(payload.get("appointmentSummary") or "").strip() or None
        invoice_reference = str(payload.get("invoiceReference") or "").strip() or None
        balance_due = payload.get("balanceDue")
        if not isinstance(balance_due, (int, float)):
            balance_due = None
        if not customer_name or not customer_email or not (service_call_id or invoice_id):
            self.write_json({"error": "Customer, email, and a job or invoice reference are required"}, status=HTTPStatus.BAD_REQUEST)
            return
        if any(len(value) > limit for value, limit in ((customer_name, 300), (customer_email, 254), (title, 200), (appointment_summary or "", 600), (invoice_reference or "", 160), (service_call_id or "", 80), (invoice_id or "", 80))):
            self.write_json({"error": "Portal link fields are too long"}, status=HTTPStatus.BAD_REQUEST)
            return
        requested_days = payload.get("expiresInDays", 14)
        try:
            expires_in_days = int(requested_days)
        except (TypeError, ValueError):
            self.write_json({"error": "Invalid portal expiry"}, status=HTTPStatus.BAD_REQUEST)
            return
        if not 1 <= expires_in_days <= CUSTOMER_PORTAL_MAX_DAYS:
            self.write_json({"error": f"Portal expiry must be between 1 and {CUSTOMER_PORTAL_MAX_DAYS} days"}, status=HTTPStatus.BAD_REQUEST)
            return
        token = secrets.token_urlsafe(32)
        link_id = str(uuid.uuid4())
        created_at = utc_now()
        expires_at = (datetime.now(timezone.utc) + timedelta(days=expires_in_days)).isoformat()
        principal = self.principal() or {}
        actor = principal.get("email") if isinstance(principal.get("email"), str) else "unknown"
        with db() as connection:
            connection.execute(
                """
                INSERT INTO customer_portal_links(
                    id, token_hash, customer_name, customer_email, service_call_id, invoice_id,
                    title, appointment_summary, invoice_reference, balance_due, expires_at,
                    created_at, created_by
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (link_id, portal_token_hash(token), customer_name, customer_email, service_call_id, invoice_id, title, appointment_summary, invoice_reference, balance_due, expires_at, created_at, actor),
            )
        record_audit_event(actor, "create", "customer-portal-link", link_id)
        self.write_json({"id": link_id, "url": portal_url(token), "expiresAt": expires_at}, status=HTTPStatus.CREATED)

    def render_customer_portal(self, token: str) -> None:
        if not CUSTOMER_PORTAL_ENABLED or not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", token):
            self.write_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND, require_auth=False)
            return
        with db() as connection:
            row = connection.execute(
                "SELECT * FROM customer_portal_links WHERE token_hash = ? AND revoked_at IS NULL",
                (portal_token_hash(token),),
            ).fetchone()
        if row is None or datetime.fromisoformat(row["expires_at"]) <= datetime.now(timezone.utc):
            self.write_json({"error": "This customer link is unavailable"}, status=HTTPStatus.NOT_FOUND, require_auth=False)
            return
        items = [("Appointment", row["appointment_summary"]), ("Invoice", row["invoice_reference"])]
        if row["balance_due"] is not None:
            items.append(("Balance due", f"${float(row['balance_due']):,.2f}"))
        detail_rows = "".join(f"<dt>{html.escape(label)}</dt><dd>{html.escape(str(value))}</dd>" for label, value in items if value)
        content = f"""<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>GunnAire service update</title><style>body{{font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:42rem;margin:3rem auto;padding:0 1.25rem;color:#171717}}main{{border:1px solid #ddd;border-radius:16px;padding:1.5rem}}dt{{font-weight:600;margin-top:1rem}}dd{{margin:.2rem 0}}small{{color:#666}}</style><main><h1>{html.escape(row['title'])}</h1><p>Hello {html.escape(row['customer_name'])},</p><dl>{detail_rows}</dl><p>Please contact GunnAire to request changes or ask a question.</p><small>This secure link expires {html.escape(row['expires_at'])}. Do not forward it.</small></main></html>"""
        data = content.encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def store_public_service_request(self) -> None:
        if not PUBLIC_BOOKING_ENABLED:
            self.write_json({"error": "Online booking is not enabled"}, status=HTTPStatus.NOT_FOUND, require_auth=False)
            return
        client_ip = (self.headers.get("X-Forwarded-For", "").split(",")[0].strip() or self.client_address[0])
        now_timestamp = datetime.now(timezone.utc).timestamp()
        with PUBLIC_BOOKING_LOCK:
            attempts = [value for value in PUBLIC_BOOKING_ATTEMPTS.get(client_ip, []) if now_timestamp - value < PUBLIC_BOOKING_RATE_WINDOW_SECONDS]
            if len(attempts) >= PUBLIC_BOOKING_RATE_LIMIT:
                self.write_json({"error": "Too many requests. Please call the office."}, status=HTTPStatus.TOO_MANY_REQUESTS, require_auth=False)
                return
            attempts.append(now_timestamp)
            PUBLIC_BOOKING_ATTEMPTS[client_ip] = attempts
        try:
            payload = self.read_json()
        except (json.JSONDecodeError, UnicodeDecodeError):
            self.write_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST, require_auth=False)
            return
        if str(payload.get("website", "")).strip():  # Honeypot; never reveal the rejection reason.
            self.write_json({"accepted": True}, status=HTTPStatus.ACCEPTED, require_auth=False)
            return
        customer_name = str(payload.get("customerName") or "").strip()
        phone = str(payload.get("phone") or "").strip()
        email = normalize_email(payload.get("email") if isinstance(payload.get("email"), str) else None)
        address = str(payload.get("address") or "").strip()
        summary = str(payload.get("summary") or "").strip()
        service_type = str(payload.get("requestedServiceType") or "service").strip().lower()
        urgency = str(payload.get("urgency") or "normal").strip().lower()
        preferred_date = str(payload.get("preferredDate") or "").strip() or None
        if not bool(payload.get("contactConsent")):
            self.write_json({"error": "Contact consent is required"}, status=HTTPStatus.BAD_REQUEST, require_auth=False)
            return
        if not customer_name or (not phone and not email) or not summary:
            self.write_json({"error": "Name, phone or email, and service request are required"}, status=HTTPStatus.BAD_REQUEST, require_auth=False)
            return
        if len(customer_name) > 120 or len(phone) > 40 or len(email) > 254 or len(address) > 300 or len(summary) > 2000:
            self.write_json({"error": "Request contains fields that are too long"}, status=HTTPStatus.BAD_REQUEST, require_auth=False)
            return
        if service_type not in {"service", "estimate", "install", "maintenance"} or urgency not in {"normal", "priority", "emergency"}:
            self.write_json({"error": "Unsupported request type"}, status=HTTPStatus.BAD_REQUEST, require_auth=False)
            return
        request_id, created_at = str(uuid.uuid4()), utc_now()
        with db() as connection:
            connection.execute(
                "INSERT INTO public_service_requests VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)",
                (request_id, customer_name, phone or None, email or None, address or None, service_type, urgency, summary, preferred_date, created_at),
            )
        self.write_json({"accepted": True, "requestID": request_id}, status=HTTPStatus.ACCEPTED, require_auth=False)

    def claim_public_service_request(self, request_id: str) -> None:
        if not request_id or len(request_id) > 80:
            self.write_json({"error": "Invalid request ID"}, status=HTTPStatus.BAD_REQUEST)
            return
        principal = self.principal() or {}
        with db() as connection:
            result = connection.execute(
                "UPDATE public_service_requests SET claimed_at = ?, claimed_by = ? WHERE id = ? AND claimed_at IS NULL",
                (utc_now(), principal.get("email"), request_id),
            )
        if result.rowcount == 1:
            record_audit_event(principal.get("email") if isinstance(principal.get("email"), str) else None, "claim", "service-request", request_id)
        self.write_json({"claimed": result.rowcount == 1, "id": request_id})

    def upsert_user(self) -> None:
        try:
            payload = self.read_json()
        except json.JSONDecodeError:
            self.write_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return

        email = normalize_email(payload.get("email") if isinstance(payload.get("email"), str) else None)
        role = payload.get("role") if isinstance(payload.get("role"), str) else "Standard"
        is_active = bool(payload.get("isActive", True))

        if not email.endswith("@gunnaire.com"):
            self.write_json({"error": "Only gunnaire.com users are allowed"}, status=HTTPStatus.BAD_REQUEST)
            return
        role_by_key = {
            "admin": "Admin",
            "standard": "Standard",
            "field technician": "Field Technician",
            "fieldtechnician": "Field Technician",
            "dispatcher": "Dispatcher",
            "accounting": "Accounting",
        }
        normalized_role = role_by_key.get(role.strip().lower())
        if normalized_role is None:
            self.write_json(
                {"error": "Role must be Admin, Standard, Field Technician, Dispatcher, or Accounting"},
                status=HTTPStatus.BAD_REQUEST,
            )
            return
        if email == PRIMARY_ADMIN_EMAIL:
            normalized_role = "Admin"
            is_active = True

        now = utc_now()
        with db() as connection:
            connection.execute(
                """
                INSERT INTO users(email, role, is_active, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(email) DO UPDATE SET
                    role = excluded.role,
                    is_active = excluded.is_active,
                    updated_at = excluded.updated_at
                """,
                (email, normalized_role, 1 if is_active else 0, now, now),
            )
            row = connection.execute("SELECT * FROM users WHERE email = ?", (email,)).fetchone()
        principal = self.principal() or {}
        record_audit_event(principal.get("email") if isinstance(principal.get("email"), str) else None, "upsert", "user", email)
        self.write_json(user_record(row), status=HTTPStatus.CREATED)

    def exchange_qbo_authorization_code(self) -> None:
        try:
            payload = self.read_json()
        except json.JSONDecodeError:
            self.write_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return
        code = payload.get("code") if isinstance(payload.get("code"), str) else ""
        realm_id = payload.get("realmID") if isinstance(payload.get("realmID"), str) else ""
        environment = payload.get("environment") if isinstance(payload.get("environment"), str) else ""
        if not code.strip() or len(code) > 4096:
            self.write_json({"error": "Invalid authorization code"}, status=HTTPStatus.BAD_REQUEST)
            return
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", realm_id.strip()):
            self.write_json({"error": "Invalid QuickBooks company realm"}, status=HTTPStatus.BAD_REQUEST)
            return
        if environment.strip().lower() != QBO_ENVIRONMENT:
            self.write_json({"error": "QuickBooks environment does not match this backend"}, status=HTTPStatus.CONFLICT)
            return
        if not qbo_token_storage_is_configured():
            self.write_json({"error": "QuickBooks encrypted token storage is not configured"}, status=HTTPStatus.SERVICE_UNAVAILABLE)
            return
        status, result = qbo_request(
            {"grant_type": "authorization_code", "code": code, "redirect_uri": QBO_REDIRECT_URI},
            QBO_TOKEN_ENDPOINT,
        )
        token_response = qbo_token_response(result)
        if status < 200 or status >= 300 or token_response is None:
            self.write_json({"error": "QuickBooks authorization exchange failed"}, status=HTTPStatus.BAD_GATEWAY)
            return
        now = utc_now()
        try:
            encrypted_refresh_token = encrypt_qbo_refresh_token(str(token_response["refreshToken"]))
        except RuntimeError:
            self.write_json({"error": "QuickBooks encrypted token storage is not configured"}, status=HTTPStatus.SERVICE_UNAVAILABLE)
            return
        with db() as connection:
            connection.execute(
                """
                INSERT INTO qbo_connections(
                    id, realm_id, refresh_token_ciphertext, environment,
                    client_id_fingerprint, authorized_at, updated_at
                ) VALUES (1, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    realm_id = excluded.realm_id,
                    refresh_token_ciphertext = excluded.refresh_token_ciphertext,
                    environment = excluded.environment,
                    client_id_fingerprint = excluded.client_id_fingerprint,
                    authorized_at = excluded.authorized_at,
                    updated_at = excluded.updated_at
                """,
                (
                    realm_id.strip(),
                    encrypted_refresh_token,
                    QBO_ENVIRONMENT,
                    hashlib.sha256(QBO_CLIENT_ID.encode("utf-8")).hexdigest(),
                    now,
                    now,
                ),
            )
        principal = self.principal() or {}
        record_audit_event(principal.get("email") if isinstance(principal.get("email"), str) else None, "authorize", "quickbooks")
        self.write_json(qbo_client_token_response(result))

    def refresh_qbo_access_token(self) -> None:
        try:
            payload = self.read_json()
        except json.JSONDecodeError:
            self.write_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return
        realm_id = payload.get("realmID") if isinstance(payload.get("realmID"), str) else ""
        environment = payload.get("environment") if isinstance(payload.get("environment"), str) else ""
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", realm_id.strip()) or environment.strip().lower() not in {"sandbox", "production"}:
            self.write_json({"error": "Invalid QuickBooks connection context"}, status=HTTPStatus.BAD_REQUEST)
            return
        if not qbo_token_storage_is_configured():
            self.write_json({"error": "QuickBooks encrypted token storage is not configured"}, status=HTTPStatus.SERVICE_UNAVAILABLE)
            return
        with db() as connection:
            connection_row = connection.execute(
                "SELECT realm_id, environment, refresh_token_ciphertext FROM qbo_connections WHERE id = 1"
            ).fetchone()
        if connection_row is None:
            self.write_json({"error": "QuickBooks is not connected"}, status=HTTPStatus.CONFLICT)
            return
        if not qbo_connection_matches(connection_row, realm_id.strip(), environment.strip().lower()):
            self.write_json({"error": "QuickBooks company or environment differs; reconnect QuickBooks"}, status=HTTPStatus.CONFLICT)
            return
        refresh_token = decrypt_qbo_refresh_token(connection_row["refresh_token_ciphertext"])
        if not refresh_token:
            self.write_json({"error": "QuickBooks stored authorization is unreadable; reconnect QuickBooks"}, status=HTTPStatus.CONFLICT)
            return
        status, result = qbo_request({"grant_type": "refresh_token", "refresh_token": refresh_token}, QBO_TOKEN_ENDPOINT)
        token_response = qbo_token_response(result)
        if status < 200 or status >= 300 or token_response is None:
            self.write_json({"error": "QuickBooks token refresh failed"}, status=HTTPStatus.BAD_GATEWAY)
            return
        try:
            encrypted_refresh_token = encrypt_qbo_refresh_token(str(token_response["refreshToken"]))
        except RuntimeError:
            self.write_json({"error": "QuickBooks encrypted token storage is not configured"}, status=HTTPStatus.SERVICE_UNAVAILABLE)
            return
        with db() as connection:
            connection.execute(
                "UPDATE qbo_connections SET refresh_token_ciphertext = ?, updated_at = ? WHERE id = 1",
                (encrypted_refresh_token, utc_now()),
            )
        principal = self.principal() or {}
        record_audit_event(principal.get("email") if isinstance(principal.get("email"), str) else None, "refresh", "quickbooks")
        self.write_json(qbo_client_token_response(result))

    def revoke_qbo_token(self) -> None:
        if not qbo_token_storage_is_configured():
            self.write_json({"error": "QuickBooks encrypted token storage is not configured"}, status=HTTPStatus.SERVICE_UNAVAILABLE)
            return
        with db() as connection:
            connection_row = connection.execute(
                "SELECT refresh_token_ciphertext FROM qbo_connections WHERE id = 1"
            ).fetchone()
        if connection_row is None:
            self.write_json({"revoked": True})
            return
        token = decrypt_qbo_refresh_token(connection_row["refresh_token_ciphertext"])
        if not token:
            self.write_json({"error": "QuickBooks stored authorization is unreadable; reconnect QuickBooks"}, status=HTTPStatus.CONFLICT)
            return
        status, _ = qbo_request({"token": token}, QBO_REVOCATION_ENDPOINT)
        if status < 200 or status >= 300:
            self.write_json({"error": "QuickBooks token revocation failed"}, status=HTTPStatus.BAD_GATEWAY)
            return
        with db() as connection:
            connection.execute("DELETE FROM qbo_connections WHERE id = 1")
        principal = self.principal() or {}
        record_audit_event(principal.get("email") if isinstance(principal.get("email"), str) else None, "revoke", "quickbooks")
        self.write_json({"revoked": True})

    def store_document(self) -> None:
        # Base64 adds roughly one third overhead. Reject oversized declared
        # requests before reading them into memory, then verify the decoded size.
        declared_length = self.headers.get("Content-Length", "0")
        try:
            if int(declared_length) > ((MAX_DOCUMENT_BYTES * 4) // 3) + 8192:
                self.write_json({"error": "Document exceeds the configured upload limit"}, status=HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
                return
        except ValueError:
            self.write_json({"error": "Invalid Content-Length"}, status=HTTPStatus.BAD_REQUEST)
            return
        try:
            payload = self.read_json()
        except json.JSONDecodeError:
            self.write_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return

        filename = safe_filename(str(payload.get("filename") or "upload.bin"))
        content_type = str(payload.get("contentType") or "application/octet-stream")
        kind = safe_filename(str(payload.get("kind") or "document")).lower()
        data_base64 = payload.get("dataBase64")
        if not isinstance(data_base64, str) or not data_base64:
            self.write_json({"error": "Missing dataBase64"}, status=HTTPStatus.BAD_REQUEST)
            return

        try:
            data = base64.b64decode(data_base64, validate=True)
        except ValueError:
            self.write_json({"error": "Invalid base64 document data"}, status=HTTPStatus.BAD_REQUEST)
            return
        if len(data) > MAX_DOCUMENT_BYTES:
            self.write_json({"error": "Document exceeds the configured upload limit"}, status=HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
            return

        references = {}
        for payload_key, column_name in (
            ("serviceCallID", "service_call_id"),
            ("invoiceID", "invoice_id"),
            ("estimateID", "estimate_id"),
            ("customerEquipmentID", "customer_equipment_id"),
        ):
            value = payload.get(payload_key) if isinstance(payload.get(payload_key), str) else None
            if value is not None and len(value.strip()) > 80:
                self.write_json({"error": f"{payload_key} is too long"}, status=HTTPStatus.BAD_REQUEST)
                return
            references[column_name] = value.strip() if value and value.strip() else None
        service_call_id = references["service_call_id"]
        invoice_id = references["invoice_id"]
        estimate_id = references["estimate_id"]
        customer_equipment_id = references["customer_equipment_id"]
        if (invoice_id or estimate_id or kind in {
            "invoice", "estimate", "payment", "receipt", "bill", "financial",
            "credit", "statement", "transaction",
        }) and not self.has_billing_document_access():
            self.write_json(
                {"error": "Financial access is required to store billing documents"},
                status=HTTPStatus.FORBIDDEN,
            )
            return
        equipment_name = str(payload.get("equipmentName") or "").strip() or None
        customer_name = payload.get("customerName") if isinstance(payload.get("customerName"), str) else None
        if (equipment_name and len(equipment_name) > 300) or (customer_name and len(customer_name) > 300):
            self.write_json({"error": "Document metadata is too long"}, status=HTTPStatus.BAD_REQUEST)
            return
        # Do not create a file until every request field has been accepted.
        document_id = str(uuid.uuid4())
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        destination_dir = STORAGE_ROOT / kind / today
        destination_dir.mkdir(parents=True, exist_ok=True)
        destination = destination_dir / f"{document_id}-{filename}"
        try:
            destination.write_bytes(data)
        except OSError:
            self.write_json({"error": "Company document storage is unavailable"}, status=HTTPStatus.SERVICE_UNAVAILABLE)
            return
        created_at = utc_now()
        with db() as connection:
            connection.execute(
                """
                INSERT INTO documents(
                    id, filename, content_type, kind, service_call_id, invoice_id, estimate_id,
                    customer_equipment_id, equipment_name, customer_name, stored_path, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    document_id,
                    filename,
                    content_type,
                    kind,
                    service_call_id,
                    invoice_id,
                    estimate_id,
                    customer_equipment_id,
                    equipment_name,
                    customer_name,
                    str(destination),
                    created_at,
                ),
            )

        principal = self.principal() or {}
        record_audit_event(principal.get("email") if isinstance(principal.get("email"), str) else None, "upload", "document", document_id)

        self.write_json(
            {
                "id": document_id,
                "filename": filename,
                "createdAt": created_at,
            },
            status=HTTPStatus.CREATED,
        )

    def create_field_payment_assignment(self) -> None:
        try:
            payload = self.read_json()
        except json.JSONDecodeError:
            self.write_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return

        invoice_id = str(payload.get("invoiceID") or "").strip()
        customer_name = str(payload.get("customerName") or "").strip()
        assigned_to = normalize_email(payload.get("assignedTo") if isinstance(payload.get("assignedTo"), str) else None)
        try:
            amount = float(payload.get("amount"))
        except (TypeError, ValueError):
            self.write_json({"error": "Assignment amount must be numeric"}, status=HTTPStatus.BAD_REQUEST)
            return
        if not invoice_id or not customer_name or not assigned_to:
            self.write_json({"error": "Invoice, customer, and assigned technician are required"}, status=HTTPStatus.BAD_REQUEST)
            return
        if amount <= 0 or amount > 1_000_000:
            self.write_json({"error": "Assignment amount must be greater than zero and within the approved limit"}, status=HTTPStatus.BAD_REQUEST)
            return

        principal = self.principal() or {}
        assigned_by = normalize_email(principal.get("email") if isinstance(principal.get("email"), str) else None)
        with db() as connection:
            technician = connection.execute(
                "SELECT role, is_active FROM users WHERE email = ?",
                (assigned_to,),
            ).fetchone()
            if technician is None or not bool(technician["is_active"]) or technician["role"] != "Field Technician":
                self.write_json({"error": "Assignments must target an active field technician"}, status=HTTPStatus.BAD_REQUEST)
                return
            existing = connection.execute(
                """
                SELECT * FROM field_payment_assignments
                WHERE invoice_id = ? AND assigned_to = ? AND status IN ('pending', 'accepted')
                ORDER BY created_at DESC LIMIT 1
                """,
                (invoice_id, assigned_to),
            ).fetchone()
            if existing is not None:
                self.write_json(
                    {"assignment": field_payment_assignment_record(existing), "idempotentReplay": True},
                    status=HTTPStatus.OK,
                )
                return
            assignment_id = str(uuid.uuid4())
            created_at = utc_now()
            connection.execute(
                """
                INSERT INTO field_payment_assignments(
                    id, invoice_id, customer_name, amount, assigned_to, assigned_by, status, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
                """,
                (assignment_id, invoice_id, customer_name, amount, assigned_to, assigned_by, created_at),
            )
            row = connection.execute(
                "SELECT * FROM field_payment_assignments WHERE id = ?", (assignment_id,)
            ).fetchone()
        record_audit_event(assigned_by, "assign", "field-payment", assignment_id)
        self.write_json({"assignment": field_payment_assignment_record(row)}, status=HTTPStatus.CREATED)

    def accept_field_payment_assignment(self, assignment_id: str) -> None:
        if not re.fullmatch(r"[0-9a-fA-F-]{36}", assignment_id):
            self.write_json({"error": "Invalid field collection assignment"}, status=HTTPStatus.BAD_REQUEST)
            return
        principal = self.principal() or {}
        email = normalize_email(principal.get("email") if isinstance(principal.get("email"), str) else None)
        role = principal.get("role")
        with db() as connection:
            row = connection.execute(
                "SELECT * FROM field_payment_assignments WHERE id = ?", (assignment_id,)
            ).fetchone()
            if row is None:
                self.write_json({"error": "Field collection assignment not found"}, status=HTTPStatus.NOT_FOUND)
                return
            can_accept = role in {"Admin", "Accounting", "Dispatcher"} or row["assigned_to"] == email
            if not can_accept:
                self.write_json({"error": "This collection assignment belongs to another technician"}, status=HTTPStatus.FORBIDDEN)
                return
            if row["status"] == "cancelled":
                self.write_json({"error": "This collection assignment was cancelled"}, status=HTTPStatus.CONFLICT)
                return
            if row["status"] == "pending":
                connection.execute(
                    "UPDATE field_payment_assignments SET status = 'accepted', accepted_at = ? WHERE id = ?",
                    (utc_now(), assignment_id),
                )
                row = connection.execute(
                    "SELECT * FROM field_payment_assignments WHERE id = ?", (assignment_id,)
                ).fetchone()
        record_audit_event(email, "accept", "field-payment", assignment_id)
        self.write_json({"assignment": field_payment_assignment_record(row)})

    def cancel_field_payment_assignment(self, assignment_id: str) -> None:
        if not re.fullmatch(r"[0-9a-fA-F-]{36}", assignment_id):
            self.write_json({"error": "Invalid field collection assignment"}, status=HTTPStatus.BAD_REQUEST)
            return
        principal = self.principal() or {}
        actor = normalize_email(principal.get("email") if isinstance(principal.get("email"), str) else None)
        with db() as connection:
            row = connection.execute(
                "SELECT * FROM field_payment_assignments WHERE id = ?", (assignment_id,)
            ).fetchone()
            if row is None:
                self.write_json({"error": "Field collection assignment not found"}, status=HTTPStatus.NOT_FOUND)
                return
            if row["status"] != "cancelled":
                connection.execute(
                    """
                    UPDATE field_payment_assignments
                    SET status = 'cancelled', cancelled_at = ?, cancelled_by = ?
                    WHERE id = ?
                    """,
                    (utc_now(), actor, assignment_id),
                )
                row = connection.execute(
                    "SELECT * FROM field_payment_assignments WHERE id = ?", (assignment_id,)
                ).fetchone()
        record_audit_event(actor, "cancel", "field-payment", assignment_id)
        self.write_json({"assignment": field_payment_assignment_record(row)})

    def store_payment_collection(self) -> None:
        try:
            payload = self.read_json()
        except json.JSONDecodeError:
            self.write_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return

        payment_id = str(payload.get("paymentID") or "").strip()
        customer_name = str(payload.get("customerName") or "").strip()
        method = str(payload.get("method") or "").strip().lower()
        collected_at = str(payload.get("collectedAt") or "").strip() or utc_now()
        try:
            amount = float(payload.get("amount"))
        except (TypeError, ValueError):
            self.write_json({"error": "Payment amount must be numeric"}, status=HTTPStatus.BAD_REQUEST)
            return

        if not payment_id:
            self.write_json({"error": "Missing paymentID"}, status=HTTPStatus.BAD_REQUEST)
            return
        if not customer_name:
            self.write_json({"error": "Missing customerName"}, status=HTTPStatus.BAD_REQUEST)
            return
        if amount <= 0:
            self.write_json({"error": "Payment amount must be greater than zero"}, status=HTTPStatus.BAD_REQUEST)
            return
        if method not in {"card", "ach", "cash", "check"}:
            self.write_json({"error": "Payment method must be card, ach, cash, or check"}, status=HTTPStatus.BAD_REQUEST)
            return

        record_id = str(uuid.uuid4())
        created_at = utc_now()
        invoice_id = payload.get("invoiceID") if isinstance(payload.get("invoiceID"), str) else None
        invoice_quickbooks_id = payload.get("invoiceQuickBooksID") if isinstance(payload.get("invoiceQuickBooksID"), str) else None
        customer_email = payload.get("customerEmail") if isinstance(payload.get("customerEmail"), str) else None
        card_last4 = payload.get("cardLast4") if isinstance(payload.get("cardLast4"), str) else None
        authorization_reference = payload.get("authorizationReference") if isinstance(payload.get("authorizationReference"), str) else None
        processor = payload.get("processor") if isinstance(payload.get("processor"), str) else None
        notes = payload.get("notes") if isinstance(payload.get("notes"), str) else None
        collected_by = payload.get("collectedBy") if isinstance(payload.get("collectedBy"), str) else None
        with db() as connection:
            existing = connection.execute(
                "SELECT * FROM payment_collections WHERE payment_id = ?",
                (payment_id,),
            ).fetchone()
            if existing is not None:
                same_payment = (
                    existing["invoice_id"] == invoice_id
                    and existing["invoice_quickbooks_id"] == invoice_quickbooks_id
                    and existing["customer_name"] == customer_name
                    and abs(float(existing["amount"]) - amount) <= 0.0001
                    and existing["method"] == method
                    and existing["authorization_reference"] == authorization_reference
                )
                if not same_payment:
                    self.write_json(
                        {"error": "Payment ID already exists with different accounting details"},
                        status=HTTPStatus.CONFLICT,
                    )
                    return
                self.write_json(
                    {
                        "id": existing["id"],
                        "paymentID": existing["payment_id"],
                        "createdAt": existing["created_at"],
                        "idempotentReplay": True,
                    },
                    status=HTTPStatus.OK,
                )
                return
            connection.execute(
                """
                INSERT INTO payment_collections(
                    id, payment_id, invoice_id, invoice_quickbooks_id, customer_name,
                    customer_email, amount, method, card_last4, authorization_reference,
                    processor, notes, collected_by, collected_at, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    record_id,
                    payment_id,
                    invoice_id,
                    invoice_quickbooks_id,
                    customer_name,
                    customer_email,
                    amount,
                    method,
                    card_last4,
                    authorization_reference,
                    processor,
                    notes,
                    collected_by,
                    collected_at,
                    created_at,
                ),
            )
            row = connection.execute(
                "SELECT id, payment_id, created_at FROM payment_collections WHERE payment_id = ?",
                (payment_id,),
            ).fetchone()

        principal = self.principal() or {}
        record_audit_event(principal.get("email") if isinstance(principal.get("email"), str) else None, "upsert", "payment", payment_id)

        self.write_json(
            {
                "id": row["id"],
                "paymentID": row["payment_id"],
                "createdAt": row["created_at"],
            },
            status=HTTPStatus.CREATED,
        )

    def store_customer_communication(self) -> None:
        try:
            payload = self.read_json()
        except json.JSONDecodeError:
            self.write_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return

        record_id = str(payload.get("id") or "").strip()
        customer_name = str(payload.get("customerName") or "").strip()
        recipient = normalize_email(payload.get("recipient") if isinstance(payload.get("recipient"), str) else None)
        subject = str(payload.get("subject") or "").strip()
        channel = str(payload.get("channel") or "email").strip().lower()
        direction = str(payload.get("direction") or "outbound").strip().lower()
        delivery_status = str(payload.get("deliveryStatus") or "").strip().lower()
        attachment_names = payload.get("attachmentFileNames")
        if not isinstance(attachment_names, list) or not all(isinstance(value, str) for value in attachment_names):
            self.write_json({"error": "attachmentFileNames must be a string array"}, status=HTTPStatus.BAD_REQUEST)
            return
        if not record_id or len(record_id) > 80 or not customer_name or not recipient or not subject:
            self.write_json({"error": "Missing communication identity, customer, recipient, or subject"}, status=HTTPStatus.BAD_REQUEST)
            return
        if channel != "email" or direction != "outbound" or delivery_status not in {"sent", "failed", "suppressed"}:
            self.write_json({"error": "Unsupported communication state"}, status=HTTPStatus.BAD_REQUEST)
            return

        occurred_at = str(payload.get("occurredAt") or "").strip() or utc_now()
        created_at = utc_now()
        with db() as connection:
            connection.execute(
                """
                INSERT INTO customer_communications(
                    id, customer_name, customer_email, service_call_id, invoice_id, estimate_id,
                    channel, direction, recipient, subject, delivery_status, attachment_file_names_json,
                    provider_message_id, occurred_at, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    delivery_status = excluded.delivery_status,
                    provider_message_id = excluded.provider_message_id
                """,
                (
                    record_id, customer_name,
                    payload.get("customerEmail") if isinstance(payload.get("customerEmail"), str) else None,
                    payload.get("serviceCallID") if isinstance(payload.get("serviceCallID"), str) else None,
                    payload.get("invoiceID") if isinstance(payload.get("invoiceID"), str) else None,
                    payload.get("estimateID") if isinstance(payload.get("estimateID"), str) else None,
                    channel, direction, recipient, subject, delivery_status, json.dumps(attachment_names),
                    payload.get("providerMessageID") if isinstance(payload.get("providerMessageID"), str) else None,
                    occurred_at, created_at,
                ),
            )
            row = connection.execute("SELECT * FROM customer_communications WHERE id = ?", (record_id,)).fetchone()
        principal = self.principal() or {}
        record_audit_event(principal.get("email") if isinstance(principal.get("email"), str) else None, "upsert", "customer-communication", record_id)
        self.write_json(communication_record(row), status=HTTPStatus.CREATED)

    def download_document(self, document_id: str) -> None:
        if not document_id:
            self.write_json({"error": "Missing document id"}, status=HTTPStatus.BAD_REQUEST)
            return
        with db() as connection:
            row = connection.execute(
                "SELECT * FROM documents WHERE id = ?",
                (document_id,),
            ).fetchone()
        if row is None:
            self.write_json({"error": "Document not found"}, status=HTTPStatus.NOT_FOUND)
            return
        if document_contains_financial_data(row) and not self.has_billing_document_access():
            self.write_json({"error": "Financial access required"}, status=HTTPStatus.FORBIDDEN)
            return

        stored_path = Path(row["stored_path"]).expanduser()
        try:
            resolved_storage = STORAGE_ROOT.resolve()
            resolved_file = stored_path.resolve()
        except OSError:
            self.write_json({"error": "Document path is invalid"}, status=HTTPStatus.NOT_FOUND)
            return

        if resolved_storage not in resolved_file.parents:
            self.write_json({"error": "Document path is outside storage"}, status=HTTPStatus.FORBIDDEN)
            return
        if not resolved_file.is_file():
            self.write_json({"error": "Document file is missing"}, status=HTTPStatus.NOT_FOUND)
            return

        data = resolved_file.read_bytes()
        filename = safe_filename(row["filename"])
        self.send_response(HTTPStatus.OK)
        self.send_cors_headers()
        self.send_header("Content-Type", row["content_type"] or "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.end_headers()
        self.wfile.write(data)

    def write_json(self, payload: dict[str, object], status: HTTPStatus = HTTPStatus.OK, require_auth: bool = True) -> None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_cors_headers()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_cors_headers(self) -> None:
        origin = self.headers.get("Origin", "").strip().rstrip("/")
        if origin and origin in ALLOWED_CORS_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-GunnAire-Google-ID-Token")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")

    def log_message(self, format: str, *args: object) -> None:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(f"{timestamp} {self.address_string()} {format % args}")


def main() -> None:
    if AUTH_MODE == "api-token" and not API_TOKEN:
        raise SystemExit("Set GUNNAIRE_BACKEND_API_TOKEN before starting api-token mode.")
    initialize_database()
    STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), GunnAireBackendHandler)
    print(f"GunnAire backend listening on http://{HOST}:{PORT}")
    print(f"Service version: {SERVICE_VERSION}")
    print(f"Database: {DB_PATH}")
    print(f"Storage: {STORAGE_ROOT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
