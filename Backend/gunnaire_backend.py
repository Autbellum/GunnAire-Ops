#!/usr/bin/env python3
"""Small GunnAire Ops backend for shared users, roles, documents, and field payment records."""

from __future__ import annotations

import base64
import json
import os
import re
import sqlite3
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse


HOST = os.environ.get("GUNNAIRE_BACKEND_HOST", "0.0.0.0")
PORT = int(os.environ.get("GUNNAIRE_BACKEND_PORT", "8787"))
API_TOKEN = os.environ.get("GUNNAIRE_BACKEND_API_TOKEN", "")
PRIMARY_ADMIN_EMAIL = os.environ.get("GUNNAIRE_PRIMARY_ADMIN_EMAIL", "eric.gunn@gunnaire.com").strip().lower()
DB_PATH = Path(os.environ.get("GUNNAIRE_BACKEND_DB", "gunnaire_backend.sqlite3")).expanduser()
STORAGE_ROOT = Path(os.environ.get("GUNNAIRE_BACKEND_STORAGE", "storage")).expanduser()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def normalize_email(value: str | None) -> str:
    return (value or "").strip().lower()


def safe_filename(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._ -]", "_", value.strip())
    return cleaned or "upload.bin"


def db() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(DB_PATH)
    connection.row_factory = sqlite3.Row
    return connection


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
            CREATE TABLE IF NOT EXISTS documents (
                id TEXT PRIMARY KEY,
                filename TEXT NOT NULL,
                content_type TEXT NOT NULL,
                kind TEXT NOT NULL,
                service_call_id TEXT,
                customer_name TEXT,
                stored_path TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """
        )
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


def document_record(row: sqlite3.Row) -> dict[str, object]:
    return {
        "id": row["id"],
        "filename": row["filename"],
        "contentType": row["content_type"],
        "kind": row["kind"],
        "serviceCallID": row["service_call_id"],
        "customerName": row["customer_name"],
        "storedPath": row["stored_path"],
        "createdAt": row["created_at"],
    }


class GunnAireBackendHandler(BaseHTTPRequestHandler):
    server_version = "GunnAireBackend/1.0"

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_cors_headers()
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self.write_json({"status": "ok", "time": utc_now()}, status=HTTPStatus.OK, require_auth=False)
            return
        if not self.authorized():
            self.write_json({"error": "Unauthorized"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        if parsed.path == "/api/users":
            with db() as connection:
                rows = connection.execute("SELECT * FROM users ORDER BY email").fetchall()
            self.write_json({"users": [user_record(row) for row in rows]})
            return
        if parsed.path == "/api/payments":
            with db() as connection:
                rows = connection.execute(
                    "SELECT * FROM payment_collections ORDER BY collected_at DESC, created_at DESC LIMIT 500"
                ).fetchall()
            self.write_json({"payments": [payment_collection_record(row) for row in rows]})
            return
        if parsed.path == "/api/documents":
            with db() as connection:
                rows = connection.execute(
                    "SELECT * FROM documents ORDER BY created_at DESC LIMIT 500"
                ).fetchall()
            self.write_json({"documents": [document_record(row) for row in rows]})
            return
        if parsed.path.startswith("/api/documents/") and parsed.path.endswith("/download"):
            document_id = unquote(parsed.path.removeprefix("/api/documents/").removesuffix("/download")).strip()
            self.download_document(document_id)
            return
        self.write_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if not self.authorized():
            self.write_json({"error": "Unauthorized"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        if parsed.path == "/api/users":
            self.upsert_user()
            return
        if parsed.path == "/api/documents":
            self.store_document()
            return
        if parsed.path == "/api/payments":
            self.store_payment_collection()
            return
        self.write_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def do_DELETE(self) -> None:
        parsed = urlparse(self.path)
        if not self.authorized():
            self.write_json({"error": "Unauthorized"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        if parsed.path.startswith("/api/users/"):
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
            self.write_json({"email": email, "isActive": False})
            return
        self.write_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def authorized(self) -> bool:
        if not API_TOKEN:
            return False
        expected = f"Bearer {API_TOKEN}"
        return self.headers.get("Authorization") == expected

    def read_json(self) -> dict[str, object]:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        data = self.rfile.read(length)
        return json.loads(data.decode("utf-8"))

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
        if role.lower() not in {"admin", "standard"}:
            self.write_json({"error": "Role must be Admin or Standard"}, status=HTTPStatus.BAD_REQUEST)
            return

        normalized_role = "Admin" if role.lower() == "admin" else "Standard"
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
        self.write_json(user_record(row), status=HTTPStatus.CREATED)

    def store_document(self) -> None:
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

        document_id = str(uuid.uuid4())
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        destination_dir = STORAGE_ROOT / kind / today
        destination_dir.mkdir(parents=True, exist_ok=True)
        destination = destination_dir / f"{document_id}-{filename}"
        destination.write_bytes(data)

        service_call_id = payload.get("serviceCallID") if isinstance(payload.get("serviceCallID"), str) else None
        customer_name = payload.get("customerName") if isinstance(payload.get("customerName"), str) else None
        created_at = utc_now()
        with db() as connection:
            connection.execute(
                """
                INSERT INTO documents(id, filename, content_type, kind, service_call_id, customer_name, stored_path, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    document_id,
                    filename,
                    content_type,
                    kind,
                    service_call_id,
                    customer_name,
                    str(destination),
                    created_at,
                ),
            )

        self.write_json(
            {
                "id": document_id,
                "filename": filename,
                "storedPath": str(destination),
                "createdAt": created_at,
            },
            status=HTTPStatus.CREATED,
        )

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
        with db() as connection:
            connection.execute(
                """
                INSERT INTO payment_collections(
                    id, payment_id, invoice_id, invoice_quickbooks_id, customer_name,
                    customer_email, amount, method, card_last4, authorization_reference,
                    processor, notes, collected_by, collected_at, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(payment_id) DO UPDATE SET
                    invoice_id = excluded.invoice_id,
                    invoice_quickbooks_id = excluded.invoice_quickbooks_id,
                    customer_name = excluded.customer_name,
                    customer_email = excluded.customer_email,
                    amount = excluded.amount,
                    method = excluded.method,
                    card_last4 = excluded.card_last4,
                    authorization_reference = excluded.authorization_reference,
                    processor = excluded.processor,
                    notes = excluded.notes,
                    collected_by = excluded.collected_by,
                    collected_at = excluded.collected_at
                """,
                (
                    record_id,
                    payment_id,
                    payload.get("invoiceID") if isinstance(payload.get("invoiceID"), str) else None,
                    payload.get("invoiceQuickBooksID") if isinstance(payload.get("invoiceQuickBooksID"), str) else None,
                    customer_name,
                    payload.get("customerEmail") if isinstance(payload.get("customerEmail"), str) else None,
                    amount,
                    method,
                    payload.get("cardLast4") if isinstance(payload.get("cardLast4"), str) else None,
                    payload.get("authorizationReference") if isinstance(payload.get("authorizationReference"), str) else None,
                    payload.get("processor") if isinstance(payload.get("processor"), str) else None,
                    payload.get("notes") if isinstance(payload.get("notes"), str) else None,
                    payload.get("collectedBy") if isinstance(payload.get("collectedBy"), str) else None,
                    collected_at,
                    created_at,
                ),
            )
            row = connection.execute(
                "SELECT id, payment_id, created_at FROM payment_collections WHERE payment_id = ?",
                (payment_id,),
            ).fetchone()

        self.write_json(
            {
                "id": row["id"],
                "paymentID": row["payment_id"],
                "createdAt": row["created_at"],
            },
            status=HTTPStatus.CREATED,
        )

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
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")

    def log_message(self, format: str, *args: object) -> None:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(f"{timestamp} {self.address_string()} {format % args}")


def main() -> None:
    if not API_TOKEN:
        raise SystemExit("Set GUNNAIRE_BACKEND_API_TOKEN before starting the backend.")
    initialize_database()
    STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), GunnAireBackendHandler)
    print(f"GunnAire backend listening on http://{HOST}:{PORT}")
    print(f"Database: {DB_PATH}")
    print(f"Storage: {STORAGE_ROOT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
