#!/usr/bin/env python3
"""Small GunnAire Ops backend for shared users, roles, and document storage."""

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
