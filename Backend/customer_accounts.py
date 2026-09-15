"""Customer self-service accounts.

A customer account is a passwordless (magic-link) identity that a customer
creates from the public web portal. It starts in the 'pending' link state and
is never treated as a business customer until a staff member explicitly links
it to a real Customer record from the app (see `link_account`). Nothing here
ever grants a customer_session access to staff identity, roles, or any
CloudKit-replicated business data: a customer_session is a distinct token
namespace from `auth_sessions`, checked nowhere near `principal()`.

Invoice balance and hosted "Pay Now" link lookups reuse the existing QBO
bearer-refresh (`qbo_authorized_bearer`) and safe transport
(`qbo_payment_read_transport`) helpers from gunnaire_backend, injected by the
caller, rather than opening a second independent OAuth refresh path against
the same single-use, rotating QuickBooks refresh token.
"""
from __future__ import annotations

import hashlib
import re
import secrets
import sqlite3
import uuid
from datetime import datetime, timedelta, timezone
from typing import Callable

MAGIC_LINK_TTL_MINUTES = 15
SESSION_TTL_DAYS = 30
MAX_NAME_LENGTH = 120
MAX_PHONE_LENGTH = 40
MAX_ADDRESS_LENGTH = 300
MAX_SUMMARY_LENGTH = 2000
SUPPORTED_SERVICE_TYPES = {"service", "estimate", "install", "maintenance"}
SUPPORTED_URGENCIES = {"normal", "priority", "emergency"}


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def initialize_schema(connection: sqlite3.Connection, ensure_column: Callable[[sqlite3.Connection, str, str, str], None]) -> None:
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS customer_accounts (
            id TEXT PRIMARY KEY,
            email TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            phone TEXT,
            link_status TEXT NOT NULL DEFAULT 'pending',
            linked_customer_id TEXT,
            linked_customer_quickbooks_id TEXT,
            created_at TEXT NOT NULL,
            linked_at TEXT,
            linked_by TEXT
        )
        """
    )
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS customer_magic_links (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            token_hash TEXT NOT NULL UNIQUE,
            expires_at TEXT NOT NULL,
            consumed_at TEXT,
            created_at TEXT NOT NULL
        )
        """
    )
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS customer_sessions (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            token_hash TEXT NOT NULL UNIQUE,
            expires_at TEXT NOT NULL,
            revoked_at TEXT,
            created_at TEXT NOT NULL
        )
        """
    )
    # The public lead-intake table predates authenticated customer accounts;
    # these columns let a request from a signed-in customer be told apart
    # from an anonymous website lead without a second, parallel table.
    ensure_column(connection, "public_service_requests", "source", "TEXT")
    ensure_column(connection, "public_service_requests", "customer_account_id", "TEXT")


def normalized_email(value: str | None) -> str:
    return (value or "").strip().lower()


def is_valid_email(value: str) -> bool:
    if not value or len(value) > 254 or value.count("@") != 1:
        return False
    local_part, domain = value.rsplit("@", 1)
    if not 1 <= len(local_part) <= 64 or not domain or "." not in domain:
        return False
    return re.fullmatch(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+", local_part) is not None and re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+", domain
    ) is not None


def account_record(row: sqlite3.Row) -> dict[str, object]:
    return {
        "id": row["id"],
        "email": row["email"],
        "name": row["name"],
        "phone": row["phone"],
        "linkStatus": row["link_status"],
        "linkedCustomerID": row["linked_customer_id"],
        "linkedCustomerQuickBooksID": row["linked_customer_quickbooks_id"],
        "createdAt": row["created_at"],
        "linkedAt": row["linked_at"],
    }


def find_account_by_email(connection: sqlite3.Connection, email: str) -> sqlite3.Row | None:
    return connection.execute(
        "SELECT * FROM customer_accounts WHERE email = ?", (normalized_email(email),)
    ).fetchone()


def create_or_reuse_account(connection: sqlite3.Connection, *, email: str, name: str, phone: str | None) -> str:
    """Returns the account id, creating a pending account only if one doesn't already exist.

    An existing account's name/phone are left untouched: a repeat sign-in
    attempt should not let anyone silently overwrite an established profile.
    """
    email = normalized_email(email)
    existing = find_account_by_email(connection, email)
    if existing is not None:
        return existing["id"]
    account_id = str(uuid.uuid4())
    connection.execute(
        """
        INSERT INTO customer_accounts(id, email, name, phone, link_status, created_at)
        VALUES (?, ?, ?, ?, 'pending', ?)
        """,
        (account_id, email, name, phone, utc_now_iso()),
    )
    return account_id


def issue_magic_link(connection: sqlite3.Connection, *, account_id: str) -> str:
    token = secrets.token_urlsafe(32)
    expires_at = (datetime.now(timezone.utc) + timedelta(minutes=MAGIC_LINK_TTL_MINUTES)).isoformat()
    connection.execute(
        """
        INSERT INTO customer_magic_links(id, account_id, token_hash, expires_at, created_at)
        VALUES (?, ?, ?, ?, ?)
        """,
        (str(uuid.uuid4()), account_id, token_hash(token), expires_at, utc_now_iso()),
    )
    return token


def consume_magic_link(connection: sqlite3.Connection, *, token: str) -> str | None:
    """Validates and single-use consumes a magic-link token. Returns the account id, or None."""
    if not 16 <= len(token) <= 256:
        return None
    row = connection.execute(
        "SELECT * FROM customer_magic_links WHERE token_hash = ? AND consumed_at IS NULL",
        (token_hash(token),),
    ).fetchone()
    if row is None or row["expires_at"] < utc_now_iso():
        return None
    updated = connection.execute(
        "UPDATE customer_magic_links SET consumed_at = ? WHERE id = ? AND consumed_at IS NULL",
        (utc_now_iso(), row["id"]),
    )
    return row["account_id"] if updated.rowcount == 1 else None


def issue_session(connection: sqlite3.Connection, *, account_id: str) -> str:
    token = secrets.token_urlsafe(32)
    expires_at = (datetime.now(timezone.utc) + timedelta(days=SESSION_TTL_DAYS)).isoformat()
    connection.execute(
        """
        INSERT INTO customer_sessions(id, account_id, token_hash, expires_at, created_at)
        VALUES (?, ?, ?, ?, ?)
        """,
        (str(uuid.uuid4()), account_id, token_hash(token), expires_at, utc_now_iso()),
    )
    return token


def session_account(connection: sqlite3.Connection, *, token: str) -> sqlite3.Row | None:
    if not 16 <= len(token) <= 256:
        return None
    row = connection.execute(
        """
        SELECT customer_accounts.*, customer_sessions.expires_at AS session_expires_at,
               customer_sessions.revoked_at AS session_revoked_at
        FROM customer_sessions
        INNER JOIN customer_accounts ON customer_accounts.id = customer_sessions.account_id
        WHERE customer_sessions.token_hash = ?
        """,
        (token_hash(token),),
    ).fetchone()
    if row is None or row["session_revoked_at"] is not None or row["session_expires_at"] < utc_now_iso():
        return None
    return row


def pending_accounts(connection: sqlite3.Connection) -> list[dict[str, object]]:
    rows = connection.execute(
        "SELECT * FROM customer_accounts WHERE link_status = 'pending' ORDER BY created_at ASC LIMIT 200"
    ).fetchall()
    return [account_record(row) for row in rows]


def link_account(
    connection: sqlite3.Connection,
    *,
    account_id: str,
    customer_id: str,
    quickbooks_id: str | None,
    actor_email: str,
) -> dict[str, object] | None:
    updated = connection.execute(
        """
        UPDATE customer_accounts
        SET link_status = 'linked', linked_customer_id = ?, linked_customer_quickbooks_id = ?,
            linked_at = ?, linked_by = ?
        WHERE id = ?
        """,
        (customer_id, quickbooks_id, utc_now_iso(), actor_email, account_id),
    )
    if updated.rowcount != 1:
        return None
    row = connection.execute("SELECT * FROM customer_accounts WHERE id = ?", (account_id,)).fetchone()
    return account_record(row) if row is not None else None


def validate_service_request_fields(payload: dict[str, object]) -> tuple[dict[str, object] | None, str | None]:
    """Returns (normalized_fields, None) on success, or (None, error_message)."""
    summary = str(payload.get("summary") or "").strip()
    address = str(payload.get("address") or "").strip()
    service_type = str(payload.get("requestedServiceType") or "service").strip().lower()
    urgency = str(payload.get("urgency") or "normal").strip().lower()
    preferred_date = str(payload.get("preferredDate") or "").strip() or None
    if not summary:
        return None, "Describe what you'd like scheduled."
    if len(summary) > MAX_SUMMARY_LENGTH or len(address) > MAX_ADDRESS_LENGTH:
        return None, "Request contains fields that are too long."
    if service_type not in SUPPORTED_SERVICE_TYPES or urgency not in SUPPORTED_URGENCIES:
        return None, "Unsupported request type."
    return {
        "summary": summary,
        "address": address or None,
        "requestedServiceType": service_type,
        "urgency": urgency,
        "preferredDate": preferred_date,
    }, None


def store_customer_service_request(
    connection: sqlite3.Connection,
    *,
    account: sqlite3.Row,
    summary: str,
    address: str | None,
    requested_service_type: str,
    urgency: str,
    preferred_date: str | None,
) -> str:
    request_id = str(uuid.uuid4())
    connection.execute(
        """
        INSERT INTO public_service_requests(
            id, customer_name, phone, email, address, requested_service_type,
            urgency, summary, preferred_date, created_at, claimed_at, claimed_by,
            source, customer_account_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, 'customerPortal', ?)
        """,
        (
            request_id, account["name"], account["phone"], account["email"], address,
            requested_service_type, urgency, summary, preferred_date, utc_now_iso(), account["id"],
        ),
    )
    return request_id


# --- QuickBooks-backed invoice/balance lookup -------------------------------
#
# `transport` and `authorize_bearer` are injected so tests can substitute
# fakes; the real callers in gunnaire_backend.py pass `qbo_payment_read_transport`
# and a closure around `qbo_authorized_bearer` built from the current
# qbo_connections grant.
#
# Verified against live GunnAire QuickBooks data: card, ACH, and PayPal are
# all enabled account-wide, but `InvoiceLink` was empty on every one of the
# 10 most recent invoices, and the account has zero QBO payment links
# created. In practice this feature will show "Contact us to pay" (see
# customer_account_portal.py) for most invoices today, not a working Pay Now
# link, until invoices are sent through QBO with online payment enabled per
# invoice, or a payment link is created through some other path. Confirmed
# real, not hypothetical -- do not remove this note without re-verifying.

QBO_INVOICE_ID_PATTERN = re.compile(r"[0-9]{1,21}")


def _qbo_base_url(environment: str) -> str:
    return "https://sandbox-quickbooks.api.intuit.com" if environment == "sandbox" else "https://quickbooks.api.intuit.com"


def fetch_customer_invoices(
    *,
    quickbooks_customer_id: str,
    realm_id: str,
    environment: str,
    bearer: str,
    transport: Callable[[object], tuple[int, dict[str, object]]],
    request_factory: Callable[..., object],
    max_pay_link_lookups: int = 5,
) -> list[dict[str, object]]:
    if QBO_INVOICE_ID_PATTERN.fullmatch(quickbooks_customer_id) is None:
        return []
    query = (
        "SELECT Id, DocNumber, Balance, TotalAmt, DueDate, TxnDate FROM Invoice "
        f"WHERE CustomerRef = '{quickbooks_customer_id}' ORDERBY TxnDate DESC MAXRESULTS 50"
    )
    import urllib.parse

    list_url = (
        _qbo_base_url(environment)
        + "/v3/company/" + urllib.parse.quote(realm_id, safe="")
        + "/query?query=" + urllib.parse.quote(query, safe="")
        + "&minorversion=75"
    )
    list_request = request_factory(
        list_url, method="GET", headers={"Authorization": f"Bearer {bearer}", "Accept": "application/json"}
    )
    status, payload = transport(list_request)
    if not 200 <= status < 300:
        return []
    invoices_json = (payload.get("QueryResponse") or {}).get("Invoice") or []
    if not isinstance(invoices_json, list):
        return []

    invoices: list[dict[str, object]] = []
    pay_link_lookups_remaining = max_pay_link_lookups
    for entry in invoices_json:
        if not isinstance(entry, dict) or not isinstance(entry.get("Id"), str):
            continue
        balance = entry.get("Balance")
        record = {
            "id": entry.get("Id"),
            "docNumber": entry.get("DocNumber"),
            "balance": balance if isinstance(balance, (int, float)) else None,
            "totalAmount": entry.get("TotalAmt") if isinstance(entry.get("TotalAmt"), (int, float)) else None,
            "dueDate": entry.get("DueDate"),
            "payLink": None,
        }
        if isinstance(balance, (int, float)) and balance > 0 and pay_link_lookups_remaining > 0:
            pay_link_lookups_remaining -= 1
            record["payLink"] = _fetch_invoice_pay_link(
                invoice_id=entry["Id"], realm_id=realm_id, environment=environment,
                bearer=bearer, transport=transport, request_factory=request_factory,
            )
        invoices.append(record)
    return invoices


def _fetch_invoice_pay_link(
    *, invoice_id: str, realm_id: str, environment: str, bearer: str, transport, request_factory
) -> str | None:
    import urllib.parse

    if QBO_INVOICE_ID_PATTERN.fullmatch(invoice_id) is None:
        return None
    url = (
        _qbo_base_url(environment)
        + "/v3/company/" + urllib.parse.quote(realm_id, safe="")
        + "/invoice/" + urllib.parse.quote(invoice_id, safe="")
        + "?minorversion=75"
    )
    request = request_factory(url, method="GET", headers={"Authorization": f"Bearer {bearer}", "Accept": "application/json"})
    try:
        status, payload = transport(request)
    except Exception:
        return None
    if not 200 <= status < 300:
        return None
    invoice = payload.get("Invoice")
    if not isinstance(invoice, dict):
        return None
    link = invoice.get("InvoiceLink")
    return link if isinstance(link, str) and link.startswith("https://") else None
