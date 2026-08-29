#!/usr/bin/env python3
"""Small GunnAire Ops backend for shared users, roles, documents, and field payment records."""

from __future__ import annotations

import base64
import hashlib
import hmac
import html
import json
import math
import os
import re
import secrets
import sqlite3
import tempfile
import time
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

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa, utils


HOST = os.environ.get("GUNNAIRE_BACKEND_HOST", "0.0.0.0")
SERVICE_VERSION = "2026.08.28.13"
# Managed hosts such as Render supply PORT. Keep the GunnAire setting first so
# local/LAN deployments remain deterministic.
PORT = int(os.environ.get("GUNNAIRE_BACKEND_PORT", os.environ.get("PORT", "8787")))
API_TOKEN = os.environ.get("GUNNAIRE_BACKEND_API_TOKEN", "")
AUTH_MODE = os.environ.get("GUNNAIRE_BACKEND_AUTH_MODE", "api-token").strip().lower()
PRIMARY_ADMIN_EMAIL = os.environ.get("GUNNAIRE_PRIMARY_ADMIN_EMAIL", "eric.gunn@gunnaire.com").strip().lower()
GOOGLE_CLIENT_ID = os.environ.get("GUNNAIRE_GOOGLE_CLIENT_ID", "").strip()
GOOGLE_ALLOWED_DOMAIN = os.environ.get("GUNNAIRE_GOOGLE_ALLOWED_DOMAIN", "gunnaire.com").strip().lower()
APPLE_CLIENT_ID = os.environ.get("GUNNAIRE_APPLE_CLIENT_ID", "com.gunnaire.businesssuite").strip()
APPLE_ISSUER = "https://appleid.apple.com"
APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
APPLE_JWKS_CACHE_SECONDS = min(max(int(os.environ.get("GUNNAIRE_APPLE_JWKS_CACHE_SECONDS", "21600")), 300), 86400)
APP_SESSION_DAYS = min(max(int(os.environ.get("GUNNAIRE_APP_SESSION_DAYS", "30")), 1), 30)
APPLE_JWKS_CACHE: dict[str, object] = {"expires_at": 0.0, "keys": {}}
APPLE_JWKS_LOCK = threading.Lock()
APPLE_ACCOUNT_EVENT_TYPES = {
    "email-disabled",
    "email-enabled",
    "consent-revoked",
    "account-deleted",
}
PUSH_TOKEN_ENCRYPTION_KEY = os.environ.get("GUNNAIRE_PUSH_TOKEN_ENCRYPTION_KEY", "").strip()
APNS_TEAM_ID = os.environ.get("GUNNAIRE_APNS_TEAM_ID", "").strip()
APNS_KEY_ID = os.environ.get("GUNNAIRE_APNS_KEY_ID", "").strip()
APNS_PRIVATE_KEY_BASE64 = os.environ.get("GUNNAIRE_APNS_PRIVATE_KEY_BASE64", "").strip()
APNS_TOPIC = os.environ.get("GUNNAIRE_APNS_TOPIC", "com.gunnaire.businesssuite").strip()
APNS_DELIVERY_BATCH_SIZE = min(max(int(os.environ.get("GUNNAIRE_APNS_DELIVERY_BATCH_SIZE", "50")), 1), 200)
APNS_WORKER_INTERVAL_SECONDS = min(max(int(os.environ.get("GUNNAIRE_APNS_WORKER_INTERVAL_SECONDS", "15")), 5), 300)
APNS_AUTH_TOKEN_CACHE: dict[str, object] = {
    "configuration_fingerprint": "",
    "issued_at": 0,
    "token": "",
}
APNS_AUTH_TOKEN_LOCK = threading.Lock()
PUSH_DELIVERY_LOCK = threading.Lock()
PUSH_DELIVERY_WAKE_EVENT = threading.Event()
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
BACKUP_STATUS_PATH = Path(
    os.environ.get(
        "GUNNAIRE_BACKUP_STATUS_FILE",
        str(DATA_ROOT / "backup_status.json") if DATA_ROOT else "backup_status.json",
    )
).expanduser()
BACKUP_MAX_AGE_HOURS = min(max(int(os.environ.get("GUNNAIRE_BACKUP_MAX_AGE_HOURS", "24")), 1), 24 * 30)
QBO_CLIENT_ID = os.environ.get("GUNNAIRE_QBO_CLIENT_ID", "").strip()
QBO_CLIENT_SECRET = os.environ.get("GUNNAIRE_QBO_CLIENT_SECRET", "").strip()
QBO_REDIRECT_URI = os.environ.get("GUNNAIRE_QBO_REDIRECT_URI", "").strip()
QBO_ENVIRONMENT = os.environ.get("GUNNAIRE_QBO_ENVIRONMENT", "sandbox").strip().lower()
# A valid Fernet key is required before the confidential bridge persists a
# rotating QBO refresh token. This deliberately fails closed instead of
# downgrading production credentials to plaintext SQLite storage.
QBO_TOKEN_ENCRYPTION_KEY = os.environ.get("GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY", "").strip()
QBO_WEBHOOK_VERIFIER_TOKEN = os.environ.get("GUNNAIRE_QBO_WEBHOOK_VERIFIER_TOKEN", "").strip()
QBO_WEBHOOK_MAX_BYTES = min(max(int(os.environ.get("GUNNAIRE_QBO_WEBHOOK_MAX_BYTES", str(1024 * 1024))), 1024), 5 * 1024 * 1024)
QBO_TOKEN_ENDPOINT = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer"
QBO_REVOCATION_ENDPOINT = "https://developer.api.intuit.com/v2/oauth2/tokens/revoke"
QBO_ACCOUNTING_REFERENCE_PATTERN = re.compile(r"[A-Za-z0-9._:-]{1,128}")
QBO_SALES_ITEM_TYPES = {
    "service": "Service",
    "inventory": "Inventory",
    "noninventory": "NonInventory",
    "bundle": "Bundle",
    "group": "Group",
    "othercharge": "OtherCharge",
}
QBO_INCOME_ACCOUNT_TYPES = {
    "income": "Income",
    "other income": "Other Income",
}
QBO_EXPENSE_ACCOUNT_TYPES = {
    "expense": "Expense",
    "other expense": "Other Expense",
    "cost of goods sold": "Cost of Goods Sold",
}
SUPPLIER_CONNECTOR_IDEMPOTENCY_PATTERN = re.compile(r"[A-Za-z0-9._:-]{16,128}")
SUPPLIER_CONNECTOR_CONTRACT_VERSION = 1
SUPPLIER_CONNECTOR_MAX_REQUEST_BYTES = min(
    max(int(os.environ.get("GUNNAIRE_SUPPLIER_CONNECTOR_MAX_REQUEST_BYTES", str(64 * 1024))), 1024),
    256 * 1024,
)
SUPPLIER_CONNECTOR_DEFINITIONS: dict[str, dict[str, object]] = {
    "johnstoneDirectConnect": {
        "displayName": "Johnstone Supply DirectConnect",
        "provider": "Johnstone Supply",
        "statusWhenUnavailable": "onboardingRequired",
        "detailWhenUnavailable": "Ask the Johnstone account representative to approve DirectConnect, branch mapping, pricing, and test-order specifications.",
        "capabilities": ["catalog", "priceAvailability", "purchaseOrders"],
        "onboardingURL": "https://www.johnstonesupply.com/store101/ecommerce-tools",
    },
    "johnstonePunchOut": {
        "displayName": "Johnstone Supply Punch-out",
        "provider": "Johnstone Supply",
        "statusWhenUnavailable": "onboardingRequired",
        "detailWhenUnavailable": "Ask the Johnstone account representative for the customer-specific cXML Punch-out agreement and test credentials.",
        "capabilities": ["catalog", "priceAvailability", "purchaseOrders"],
        "onboardingURL": "https://www.johnstonesupply.com/store101/ecommerce-tools",
    },
    "lennoxPartner": {
        "displayName": "Lennox Partner",
        "provider": "Lennox",
        "statusWhenUnavailable": "partnerGated",
        "detailWhenUnavailable": "A public direct GunnAire API is not established. Obtain written Lennox partner approval and exact catalog/procurement specifications before enabling this adapter.",
        "capabilities": ["catalog", "priceAvailability", "purchaseOrders"],
        "onboardingURL": "https://www.lennoxpros.com/news/field-service-manangement-hvac",
    },
    "genericCatalog": {
        "displayName": "Generic Supplier Catalog",
        "provider": "Approved supplier",
        "statusWhenUnavailable": "adapterRequired",
        "detailWhenUnavailable": "Install an approved server adapter for the supplier's documented catalog and ordering contract.",
        "capabilities": ["catalog", "priceAvailability", "purchaseOrders"],
        "onboardingURL": None,
    },
}


class SupplierConnectorFailure(Exception):
    """Structured adapter failure that never exposes supplier response bodies or credentials."""

    def __init__(self, code: str, message: str, *, outcome_unknown: bool = False) -> None:
        super().__init__(message)
        self.code = code
        self.safe_message = message
        self.outcome_unknown = outcome_unknown


class SupplierConnectorAdapter:
    """Provider adapters are injected server-side after commercial onboarding.

    Implementations must use the supplied idempotency key with the provider, must not
    return credentials or raw provider payloads, and must recover an uncertain request
    before GunnAire permits any retry for the same key.
    """

    kind: str = ""

    def submit_order(self, order: dict[str, object], idempotency_key: str) -> dict[str, object]:
        raise NotImplementedError

    def recover_order(self, order: dict[str, object], idempotency_key: str) -> dict[str, object] | None:
        return None


SUPPLIER_CONNECTOR_ADAPTERS: dict[str, SupplierConnectorAdapter] = {}
SUPPORTED_COMMUNICATION_WORKFLOWS = {
    "general",
    "estimateFollowUp",
    "paymentReminder",
    "appointmentConfirmation",
    "technicianEnRoute",
    "technicianArrival",
    "workInProgress",
    "serviceFollowUp",
    "maintenanceVisitReminder",
    "maintenanceRenewal",
    "postJobReview",
    "receipt",
    "customerDocument",
}
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


def is_valid_email(value: str) -> bool:
    """Apply conservative syntax checks without sending or disclosing an address."""
    if not value or len(value) > 254 or value.count("@") != 1:
        return False
    local_part, domain = value.rsplit("@", 1)
    if (
        not 1 <= len(local_part) <= 64
        or local_part.startswith(".")
        or local_part.endswith(".")
        or ".." in local_part
        or not re.fullmatch(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+", local_part)
    ):
        return False
    labels = domain.split(".")
    return len(labels) >= 2 and all(
        1 <= len(label) <= 63
        and re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", label) is not None
        for label in labels
    )


def base64url_decode(value: str, *, maximum_bytes: int) -> bytes:
    if not value or len(value) > maximum_bytes * 2:
        raise ValueError("Invalid encoded value")
    padded = value + "=" * ((4 - len(value) % 4) % 4)
    try:
        decoded = base64.urlsafe_b64decode(padded.encode("ascii"))
    except (ValueError, UnicodeEncodeError) as error:
        raise ValueError("Invalid encoded value") from error
    if len(decoded) > maximum_bytes:
        raise ValueError("Encoded value is too large")
    return decoded


def base64url_encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def decode_jwt_json_segment(value: str, *, maximum_bytes: int) -> dict[str, object]:
    decoded = base64url_decode(value, maximum_bytes=maximum_bytes)
    try:
        payload = json.loads(decoded.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("Invalid token JSON") from error
    if not isinstance(payload, dict):
        raise ValueError("Invalid token JSON")
    return payload


def apple_public_key(kid: str, *, force_refresh: bool = False) -> rsa.RSAPublicKey:
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", kid):
        raise ValueError("Invalid Apple key identifier")
    now = time.monotonic()
    with APPLE_JWKS_LOCK:
        cached_keys = APPLE_JWKS_CACHE.get("keys")
        expires_at = APPLE_JWKS_CACHE.get("expires_at")
        if (
            not force_refresh
            and isinstance(cached_keys, dict)
            and isinstance(expires_at, (int, float))
            and expires_at > now
            and kid in cached_keys
            and isinstance(cached_keys[kid], rsa.RSAPublicKey)
        ):
            return cached_keys[kid]

        request = urllib.request.Request(
            APPLE_JWKS_URL,
            headers={"Accept": "application/json", "User-Agent": "GunnAireOpsBackend/1.0"},
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                raw = response.read(64 * 1024 + 1)
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise ValueError("Apple signing keys are unavailable") from error
        if len(raw) > 64 * 1024:
            raise ValueError("Apple signing-key response is too large")
        try:
            jwks = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError("Invalid Apple signing-key response") from error
        records = jwks.get("keys") if isinstance(jwks, dict) else None
        if not isinstance(records, list):
            raise ValueError("Invalid Apple signing-key response")

        parsed_keys: dict[str, rsa.RSAPublicKey] = {}
        for record in records:
            if not isinstance(record, dict) or record.get("kty") != "RSA" or record.get("alg") != "RS256":
                continue
            record_kid = record.get("kid")
            modulus = record.get("n")
            exponent = record.get("e")
            if not isinstance(record_kid, str) or not isinstance(modulus, str) or not isinstance(exponent, str):
                continue
            try:
                modulus_number = int.from_bytes(base64url_decode(modulus, maximum_bytes=1024), "big")
                exponent_number = int.from_bytes(base64url_decode(exponent, maximum_bytes=16), "big")
                parsed_keys[record_kid] = rsa.RSAPublicNumbers(exponent_number, modulus_number).public_key()
            except (ValueError, TypeError):
                continue
        if not parsed_keys:
            raise ValueError("Apple signing keys are unavailable")
        APPLE_JWKS_CACHE["keys"] = parsed_keys
        APPLE_JWKS_CACHE["expires_at"] = now + APPLE_JWKS_CACHE_SECONDS
        key = parsed_keys.get(kid)
        if key is None:
            raise ValueError("Apple signing key not found")
        return key


def verify_apple_signed_jwt(token: str) -> dict[str, object]:
    """Verify one bounded Apple RS256 JWS and return its untrusted claims only after signature success."""
    if not 100 <= len(token) <= 16 * 1024:
        raise ValueError("Invalid Apple signed token")
    segments = token.split(".")
    if len(segments) != 3:
        raise ValueError("Invalid Apple signed token")
    header = decode_jwt_json_segment(segments[0], maximum_bytes=4096)
    claims = decode_jwt_json_segment(segments[1], maximum_bytes=12 * 1024)
    if header.get("alg") != "RS256" or not isinstance(header.get("kid"), str):
        raise ValueError("Invalid Apple signed token")
    signing_key = apple_public_key(str(header["kid"]))
    signature = base64url_decode(segments[2], maximum_bytes=1024)
    try:
        signing_key.verify(
            signature,
            f"{segments[0]}.{segments[1]}".encode("ascii"),
            padding.PKCS1v15(),
            hashes.SHA256(),
        )
    except (InvalidSignature, ValueError, UnicodeEncodeError) as error:
        raise ValueError("Invalid Apple signed token") from error
    return claims


def apple_audience_matches(audience: object) -> bool:
    return audience == APPLE_CLIENT_ID or (
        isinstance(audience, list) and APPLE_CLIENT_ID in audience
    )


def verify_apple_identity_token(identity_token: str, nonce: str) -> dict[str, object]:
    if not 16 <= len(nonce) <= 200:
        raise ValueError("Invalid Apple credential")
    try:
        claims = verify_apple_signed_jwt(identity_token)
    except ValueError as error:
        raise ValueError("Invalid Apple credential") from error

    now = datetime.now(timezone.utc).timestamp()
    issuer = claims.get("iss")
    audience = claims.get("aud")
    expiration = claims.get("exp")
    issued_at = claims.get("iat")
    token_nonce = claims.get("nonce")
    subject = claims.get("sub")
    email = normalize_email(claims.get("email") if isinstance(claims.get("email"), str) else None)
    verified_claim = claims.get("email_verified")
    email_verified = verified_claim is True or (
        isinstance(verified_claim, str) and verified_claim.casefold() == "true"
    )
    if (
        issuer != APPLE_ISSUER
        or not apple_audience_matches(audience)
        or not isinstance(expiration, (int, float))
        or expiration <= now
        or not isinstance(issued_at, (int, float))
        or issued_at > now + 300
        or not isinstance(token_nonce, str)
        or not hmac.compare_digest(token_nonce, nonce)
        or not isinstance(subject, str)
        or not 1 <= len(subject) <= 255
        or not email_verified
        or not is_valid_email(email)
    ):
        raise ValueError("Invalid Apple credential")
    return claims


def verify_apple_account_notification(
    signed_payload: str,
    *,
    now: datetime | None = None,
) -> dict[str, object]:
    """Verify and normalize one Sign in with Apple account-lifecycle event."""
    try:
        claims = verify_apple_signed_jwt(signed_payload)
    except ValueError as error:
        raise ValueError("Invalid Apple account notification") from error
    checked_at = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    issuer = claims.get("iss")
    audience = claims.get("aud")
    issued_at = claims.get("iat")
    event_id = claims.get("jti")
    events = claims.get("events")
    if (
        issuer != APPLE_ISSUER
        or not apple_audience_matches(audience)
        or isinstance(issued_at, bool)
        or not isinstance(issued_at, (int, float))
        or issued_at < 0
        or issued_at > checked_at.timestamp() + 300
        or not isinstance(event_id, str)
        or not 1 <= len(event_id) <= 255
        or any(ord(character) < 33 or ord(character) > 126 for character in event_id)
        or not isinstance(events, dict)
    ):
        raise ValueError("Invalid Apple account notification")
    event_type = events.get("type")
    provider_subject = events.get("sub")
    event_time = events.get("event_time")
    if (
        event_type not in APPLE_ACCOUNT_EVENT_TYPES
        or not isinstance(provider_subject, str)
        or not 1 <= len(provider_subject) <= 255
        or any(ord(character) < 33 or ord(character) > 126 for character in provider_subject)
        or isinstance(event_time, bool)
        or not isinstance(event_time, (int, float))
        or event_time < 0
        or event_time > checked_at.timestamp() + 300
    ):
        raise ValueError("Invalid Apple account notification")
    if event_type in {"email-disabled", "email-enabled"}:
        email = normalize_email(events.get("email") if isinstance(events.get("email"), str) else None)
        private_email_claim = events.get("is_private_email")
        is_private_email = private_email_claim is True or (
            isinstance(private_email_claim, str) and private_email_claim.casefold() == "true"
        )
        if not is_valid_email(email) or not is_private_email:
            raise ValueError("Invalid Apple account notification")
    return {
        "id": event_id,
        "type": event_type,
        "providerSubject": provider_subject,
        "eventTime": datetime.fromtimestamp(float(event_time), timezone.utc).isoformat(),
    }


def verify_google_identity_token(identity_token: str) -> dict[str, object]:
    """Verify one Google OIDC token before exchanging it for an app session."""
    if AUTH_MODE != "google-id-token" or not 100 <= len(identity_token) <= 16 * 1024:
        raise ValueError("Invalid Google credential")
    try:
        claims = google_id_token.verify_oauth2_token(
            identity_token,
            google_requests.Request(),
            GOOGLE_CLIENT_ID,
        )
    except Exception as error:
        raise ValueError("Invalid Google credential") from error
    if not isinstance(claims, dict):
        raise ValueError("Invalid Google credential")
    email = normalize_email(claims.get("email") if isinstance(claims.get("email"), str) else None)
    hosted_domain = normalize_email(claims.get("hd") if isinstance(claims.get("hd"), str) else None)
    subject = claims.get("sub")
    if (
        not is_valid_email(email)
        or not bool(claims.get("email_verified"))
        or hosted_domain != GOOGLE_ALLOWED_DOMAIN
        or not isinstance(subject, str)
        or not 1 <= len(subject) <= 255
    ):
        raise ValueError("Invalid Google credential")
    return claims


def app_session_token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def create_app_session(email: str, provider: str, provider_subject: str) -> tuple[str, str]:
    token = secrets.token_urlsafe(48)
    created_at = datetime.now(timezone.utc)
    expires_at = created_at + timedelta(days=APP_SESSION_DAYS)
    with db() as connection:
        connection.execute(
            "DELETE FROM auth_sessions WHERE expires_at <= ? OR revoked_at IS NOT NULL",
            (created_at.isoformat(),),
        )
        connection.execute(
            """
            INSERT INTO auth_sessions(
                id, token_hash, email, provider, provider_subject,
                created_at, expires_at, last_used_at, revoked_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """,
            (
                str(uuid.uuid4()), app_session_token_hash(token), email, provider,
                provider_subject, created_at.isoformat(), expires_at.isoformat(), created_at.isoformat(),
            ),
        )
    return token, expires_at.isoformat()


def link_apple_identity(email: str, provider_subject: str) -> bool:
    """Persist Apple's stable subject only when it remains bound to one approved business user."""
    normalized_email = normalize_email(email)
    if (
        not is_valid_email(normalized_email)
        or not 1 <= len(provider_subject) <= 255
        or any(ord(character) < 33 or ord(character) > 126 for character in provider_subject)
    ):
        return False
    now = utc_now()
    with db() as connection:
        existing = connection.execute(
            "SELECT email FROM apple_identities WHERE provider_subject = ?",
            (provider_subject,),
        ).fetchone()
        if existing is not None and normalize_email(str(existing["email"])) != normalized_email:
            return False
        connection.execute(
            """
            INSERT INTO apple_identities(
                provider_subject, email, credential_state, relay_enabled,
                created_at, updated_at, last_event_at
            ) VALUES (?, ?, 'authorized', NULL, ?, ?, NULL)
            ON CONFLICT(provider_subject) DO UPDATE SET
                credential_state = 'authorized',
                updated_at = excluded.updated_at
            """,
            (provider_subject, normalized_email, now, now),
        )
    return True


def normalize_text_recipient(value: str | None) -> str:
    raw_value = (value or "").strip()
    if not raw_value:
        return ""
    digits = "".join(character for character in raw_value if character.isdigit())
    if not 7 <= len(digits) <= 15:
        return ""
    return f"+{digits}" if raw_value.startswith("+") else digits


def safe_filename(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._ -]", "_", value.strip())
    return cleaned or "upload.bin"


def portal_token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def customer_portal_origin(value: str | None = None) -> str | None:
    """Return one normalized HTTPS origin or fail closed on ambiguous URLs."""
    raw_value = (CUSTOMER_PORTAL_BASE_URL if value is None else value).strip()
    try:
        parsed = urlparse(raw_value)
        port = parsed.port
    except ValueError:
        return None
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        return None
    hostname = parsed.hostname.lower()
    hostname_labels = hostname.split(".")
    if not all(
        1 <= len(label) <= 63
        and re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", label) is not None
        for label in hostname_labels
    ):
        return None
    try:
        host = f"[{hostname}]" if ":" in hostname else hostname
        return f"https://{host}{f':{port}' if port is not None else ''}"
    except ValueError:
        return None


def portal_url(token: str) -> str | None:
    origin = customer_portal_origin()
    return f"{origin}/portal/{token}" if origin is not None else None


def redact_capability_tokens(value: str) -> str:
    """Keep bearer-style portal secrets out of ordinary HTTP access logs."""
    return re.sub(
        r"(?i)(/portal/)[A-Za-z0-9_-]{32,128}",
        r"\1[REDACTED]",
        value,
    )


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


def push_token_store() -> object | None:
    """Return the dedicated APNs-device-token encryptor without exposing its key."""
    if not PUSH_TOKEN_ENCRYPTION_KEY:
        return None
    try:
        from cryptography.fernet import Fernet
        return Fernet(PUSH_TOKEN_ENCRYPTION_KEY.encode("utf-8"))
    except (ImportError, ValueError):
        return None


def encrypt_push_device_token(token: str) -> str:
    encryptor = push_token_store()
    if encryptor is None:
        raise RuntimeError("Push token encryption is not configured")
    return encryptor.encrypt(token.encode("ascii")).decode("ascii")


def decrypt_push_device_token(ciphertext: str) -> str | None:
    encryptor = push_token_store()
    if encryptor is None:
        return None
    try:
        token = encryptor.decrypt(ciphertext.encode("ascii")).decode("ascii")
    except Exception:
        return None
    return token if re.fullmatch(r"[0-9a-f]{32,512}", token) and len(token) % 2 == 0 else None


def apns_configuration_is_present() -> bool:
    return bool(
        PUSH_TOKEN_ENCRYPTION_KEY
        and APNS_TEAM_ID
        and APNS_KEY_ID
        and APNS_PRIVATE_KEY_BASE64
        and APNS_TOPIC
    )


def apns_private_key() -> ec.EllipticCurvePrivateKey:
    if not re.fullmatch(r"[A-Za-z0-9]{10}", APNS_TEAM_ID):
        raise ValueError("Invalid APNs team identifier")
    if not re.fullmatch(r"[A-Za-z0-9]{10}", APNS_KEY_ID):
        raise ValueError("Invalid APNs key identifier")
    if not re.fullmatch(r"[A-Za-z0-9.-]{3,255}", APNS_TOPIC):
        raise ValueError("Invalid APNs topic")
    if APNS_TOPIC != APPLE_CLIENT_ID:
        raise ValueError("APNs topic does not match the Apple app identifier")
    try:
        encoded = APNS_PRIVATE_KEY_BASE64.encode("ascii")
        if len(encoded) > 32 * 1024:
            raise ValueError("APNs private key is too large")
        raw_key = base64.b64decode(encoded, validate=True)
        private_key = serialization.load_pem_private_key(raw_key, password=None)
    except (ValueError, TypeError, UnicodeEncodeError) as error:
        raise ValueError("Invalid APNs private key") from error
    if (
        not isinstance(private_key, ec.EllipticCurvePrivateKey)
        or not isinstance(private_key.curve, ec.SECP256R1)
    ):
        raise ValueError("APNs private key must use P-256")
    return private_key


def apns_authentication_token(now: datetime | None = None) -> str:
    issued_at = int((now or datetime.now(timezone.utc)).timestamp())
    configuration_fingerprint = hashlib.sha256(
        f"{APNS_TEAM_ID}:{APNS_KEY_ID}:{APNS_TOPIC}:{APNS_PRIVATE_KEY_BASE64}".encode("utf-8")
    ).hexdigest()
    with APNS_AUTH_TOKEN_LOCK:
        cached_token = APNS_AUTH_TOKEN_CACHE.get("token")
        cached_issued_at = APNS_AUTH_TOKEN_CACHE.get("issued_at")
        cached_fingerprint = APNS_AUTH_TOKEN_CACHE.get("configuration_fingerprint")
        if (
            isinstance(cached_token, str)
            and cached_token
            and isinstance(cached_issued_at, int)
            and 0 <= issued_at - cached_issued_at < 50 * 60
            and cached_fingerprint == configuration_fingerprint
        ):
            return cached_token

        header = base64url_encode(
            json.dumps(
                {"alg": "ES256", "kid": APNS_KEY_ID},
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
        )
        claims = base64url_encode(
            json.dumps(
                {"iss": APNS_TEAM_ID, "iat": issued_at},
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
        )
        signing_input = f"{header}.{claims}".encode("ascii")
        signature_der = apns_private_key().sign(signing_input, ec.ECDSA(hashes.SHA256()))
        signature_r, signature_s = utils.decode_dss_signature(signature_der)
        signature = signature_r.to_bytes(32, "big") + signature_s.to_bytes(32, "big")
        token = f"{header}.{claims}.{base64url_encode(signature)}"
        APNS_AUTH_TOKEN_CACHE.update(
            {
                "configuration_fingerprint": configuration_fingerprint,
                "issued_at": issued_at,
                "token": token,
            }
        )
        return token


def apns_provider_dependency_is_available() -> bool:
    try:
        import httpx  # noqa: F401
        import h2  # noqa: F401
    except ImportError:
        return False
    return True


def send_apns_request(
    *,
    device_token: str,
    environment: str,
    payload: dict[str, object],
    collapse_id: str,
) -> tuple[int, str | None, str | None]:
    """Send one privacy-minimized alert. The token and payload are never logged."""
    try:
        import httpx
    except ImportError:
        return HTTPStatus.SERVICE_UNAVAILABLE, "ProviderDependencyUnavailable", None
    host = "api.push.apple.com" if environment == "production" else "api.sandbox.push.apple.com"
    headers = {
        "authorization": f"bearer {apns_authentication_token()}",
        "apns-topic": APNS_TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": str(int(time.time()) + 24 * 60 * 60),
        "apns-collapse-id": collapse_id,
    }
    try:
        with httpx.Client(http2=True, timeout=10.0) as client:
            response = client.post(
                f"https://{host}/3/device/{device_token}",
                headers=headers,
                json=payload,
            )
    except Exception:
        return HTTPStatus.SERVICE_UNAVAILABLE, "ProviderConnectionFailed", None
    reason: str | None = None
    if response.content:
        try:
            response_payload = response.json()
            candidate = response_payload.get("reason") if isinstance(response_payload, dict) else None
            if isinstance(candidate, str) and re.fullmatch(r"[A-Za-z0-9]{1,80}", candidate):
                reason = candidate
        except (ValueError, TypeError):
            reason = "MalformedProviderResponse"
    apns_id = response.headers.get("apns-id")
    if apns_id is not None and not re.fullmatch(r"[0-9a-fA-F-]{36}", apns_id):
        apns_id = None
    return response.status_code, reason, apns_id


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


QBO_WEBHOOK_TYPE_PATTERN = re.compile(
    r"^qbo\.([a-z0-9-]{1,64})\.(created|updated|deleted|voided|merged|activated|deactivated)\.v1$"
)


def verify_qbo_webhook_signature(payload: bytes, signature: str | None) -> bool:
    """Verify Intuit's base64 HMAC-SHA256 signature over the exact raw body."""
    if not QBO_WEBHOOK_VERIFIER_TOKEN or not signature:
        return False
    expected = base64.b64encode(
        hmac.new(
            QBO_WEBHOOK_VERIFIER_TOKEN.encode("utf-8"),
            payload,
            hashlib.sha256,
        ).digest()
    ).decode("ascii")
    return hmac.compare_digest(expected, signature.strip())


def parse_qbo_cloudevents(payload: bytes) -> list[dict[str, str]]:
    """Parse current Intuit CloudEvents v1 metadata without retaining event data."""
    decoded = json.loads(payload.decode("utf-8"))
    if not isinstance(decoded, list) or not 1 <= len(decoded) <= 200:
        raise ValueError("QuickBooks webhook must contain 1 to 200 CloudEvents")

    records: list[dict[str, str]] = []
    for event in decoded:
        if not isinstance(event, dict) or event.get("specversion") != "1.0":
            raise ValueError("Unsupported QuickBooks webhook format")
        event_id = str(event.get("id") or "").strip()
        event_type = str(event.get("type") or "").strip().lower()
        entity_id = str(event.get("intuitentityid") or "").strip()
        realm_id = str(event.get("intuitaccountid") or "").strip()
        occurred_at = str(event.get("time") or "").strip()
        type_match = QBO_WEBHOOK_TYPE_PATTERN.fullmatch(event_type)
        if not re.fullmatch(r"[A-Za-z0-9._:-]{1,200}", event_id):
            raise ValueError("Invalid QuickBooks event ID")
        if type_match is None or not re.fullmatch(r"[A-Za-z0-9._:-]{1,200}", entity_id):
            raise ValueError("Invalid QuickBooks entity event")
        if not re.fullmatch(r"[0-9]{1,32}", realm_id):
            raise ValueError("Invalid QuickBooks realm")
        try:
            occurred = datetime.fromisoformat(occurred_at.replace("Z", "+00:00"))
        except ValueError as error:
            raise ValueError("Invalid QuickBooks event time") from error
        if occurred.tzinfo is None:
            raise ValueError("QuickBooks event time must include a timezone")
        records.append(
            {
                "eventID": event_id,
                "realmID": realm_id,
                "entityType": type_match.group(1),
                "entityID": entity_id,
                "operation": type_match.group(2),
                "occurredAt": occurred.astimezone(timezone.utc).isoformat(),
            }
        )
    return records


def current_qbo_realm_id() -> str | None:
    context = current_qbo_connection_context()
    return context[0] if context is not None else None


def current_qbo_connection_context() -> tuple[str, str] | None:
    try:
        with db() as connection:
            row = connection.execute(
                "SELECT realm_id, environment FROM qbo_connections WHERE id = 1"
            ).fetchone()
    except sqlite3.Error:
        return None
    if row is None:
        return None
    return str(row["realm_id"]), str(row["environment"])


def qbo_configuration_text(payload: dict[str, object], key: str, *, maximum: int = 256) -> str:
    value = payload.get(key)
    if not isinstance(value, str):
        raise ValueError(f"Missing {key}")
    normalized = value.strip()
    if not normalized or len(normalized) > maximum or any(ord(character) < 32 for character in normalized):
        raise ValueError(f"Invalid {key}")
    return normalized


def qbo_configuration_reference(payload: dict[str, object], key: str) -> str:
    value = qbo_configuration_text(payload, key, maximum=128)
    if QBO_ACCOUNTING_REFERENCE_PATTERN.fullmatch(value) is None:
        raise ValueError(f"Invalid {key}")
    return value


def qbo_configuration_type(
    payload: dict[str, object],
    key: str,
    allowed: dict[str, str],
) -> str:
    value = qbo_configuration_text(payload, key, maximum=64)
    canonical = allowed.get(value.lower())
    if canonical is None:
        raise ValueError(f"Invalid {key}")
    return canonical


def validate_qbo_accounting_configuration(payload: dict[str, object]) -> dict[str, str]:
    """Validate realm-bound accounting defaults without accepting realm selection from a client."""
    if not isinstance(payload, dict):
        raise ValueError("Invalid QuickBooks accounting configuration")
    return {
        "defaultSalesItemRef": qbo_configuration_reference(payload, "defaultSalesItemRef"),
        "defaultSalesItemName": qbo_configuration_text(payload, "defaultSalesItemName"),
        "defaultSalesItemType": qbo_configuration_type(
            payload, "defaultSalesItemType", QBO_SALES_ITEM_TYPES
        ),
        "defaultIncomeAccountRef": qbo_configuration_reference(payload, "defaultIncomeAccountRef"),
        "defaultIncomeAccountName": qbo_configuration_text(payload, "defaultIncomeAccountName"),
        "defaultIncomeAccountType": qbo_configuration_type(
            payload, "defaultIncomeAccountType", QBO_INCOME_ACCOUNT_TYPES
        ),
        "defaultExpenseAccountRef": qbo_configuration_reference(payload, "defaultExpenseAccountRef"),
        "defaultExpenseAccountName": qbo_configuration_text(payload, "defaultExpenseAccountName"),
        "defaultExpenseAccountType": qbo_configuration_type(
            payload, "defaultExpenseAccountType", QBO_EXPENSE_ACCOUNT_TYPES
        ),
        "defaultBankAccountRef": qbo_configuration_reference(payload, "defaultBankAccountRef"),
        "defaultBankAccountName": qbo_configuration_text(payload, "defaultBankAccountName"),
        "defaultBankAccountType": qbo_configuration_type(
            payload, "defaultBankAccountType", {"bank": "Bank"}
        ),
        "defaultCreditCardAccountRef": qbo_configuration_reference(payload, "defaultCreditCardAccountRef"),
        "defaultCreditCardAccountName": qbo_configuration_text(payload, "defaultCreditCardAccountName"),
        "defaultCreditCardAccountType": qbo_configuration_type(
            payload, "defaultCreditCardAccountType", {"credit card": "Credit Card"}
        ),
    }


def supplier_connector_records() -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for kind, definition in SUPPLIER_CONNECTOR_DEFINITIONS.items():
        adapter = SUPPLIER_CONNECTOR_ADAPTERS.get(kind)
        active = adapter is not None and adapter.kind == kind
        records.append(
            {
                "contractVersion": SUPPLIER_CONNECTOR_CONTRACT_VERSION,
                "kind": kind,
                "displayName": definition["displayName"],
                "provider": definition["provider"],
                "status": "ready" if active else definition["statusWhenUnavailable"],
                "detail": (
                    "The approved server adapter is active; credentials remain server-side."
                    if active
                    else definition["detailWhenUnavailable"]
                ),
                "capabilities": list(definition["capabilities"]),
                "canSubmitOrders": active,
                "onboardingURL": definition["onboardingURL"],
            }
        )
    return records


def supplier_connector_text(
    payload: dict[str, object],
    key: str,
    *,
    maximum: int,
    required: bool = True,
) -> str | None:
    value = payload.get(key)
    if value is None and not required:
        return None
    if not isinstance(value, str):
        raise ValueError(f"Missing {key}")
    normalized = " ".join(value.strip().split())
    if not normalized:
        if required:
            raise ValueError(f"Missing {key}")
        return None
    if len(normalized) > maximum or any(ord(character) < 32 for character in normalized):
        raise ValueError(f"Invalid {key}")
    return normalized


def supplier_connector_amount(payload: dict[str, object], key: str, *, positive: bool = False) -> float:
    value = payload.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"Invalid {key}")
    amount = float(value)
    minimum = 0.0001 if positive else 0.0
    if not math.isfinite(amount) or amount < minimum or amount > 1_000_000:
        raise ValueError(f"Invalid {key}")
    return amount


def supplier_connector_timestamp(value: object, key: str, *, required: bool = True) -> str | None:
    if value is None and not required:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > 64:
        raise ValueError(f"Invalid {key}")
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"Invalid {key}") from error
    if parsed.tzinfo is None:
        raise ValueError(f"Invalid {key}")
    return parsed.astimezone(timezone.utc).isoformat()


def validate_supplier_order_request(payload: dict[str, object]) -> dict[str, object]:
    """Accept only a minimum, non-secret purchase-order snapshot from an Admin client."""
    if not isinstance(payload, dict):
        raise ValueError("Invalid supplier order")
    allowed_keys = {
        "contractVersion",
        "connectorKind",
        "purchaseOrderID",
        "purchaseOrderNumber",
        "serviceCallID",
        "vendorName",
        "itemName",
        "internalSKU",
        "supplierPartNumber",
        "quantity",
        "expectedUnitCost",
        "expectedShippingCost",
        "currencyCode",
        "supplierLocation",
        "priceAvailabilityCheckedAt",
        "orderNotes",
    }
    if set(payload) - allowed_keys:
        raise ValueError("Supplier order contains unsupported fields")
    contract_version = payload.get("contractVersion")
    if isinstance(contract_version, bool) or contract_version != SUPPLIER_CONNECTOR_CONTRACT_VERSION:
        raise ValueError("Unsupported supplier connector contract version")
    connector_kind = supplier_connector_text(payload, "connectorKind", maximum=64)
    if connector_kind not in SUPPLIER_CONNECTOR_DEFINITIONS:
        raise ValueError("Unsupported supplier connector")
    purchase_order_id = supplier_connector_text(payload, "purchaseOrderID", maximum=36)
    try:
        purchase_order_id = str(uuid.UUID(purchase_order_id))
    except (ValueError, AttributeError) as error:
        raise ValueError("Invalid purchaseOrderID") from error
    service_call_id = supplier_connector_text(payload, "serviceCallID", maximum=36, required=False)
    if service_call_id is not None:
        try:
            service_call_id = str(uuid.UUID(service_call_id))
        except ValueError as error:
            raise ValueError("Invalid serviceCallID") from error
    currency_code = supplier_connector_text(payload, "currencyCode", maximum=3)
    if currency_code.upper() != "USD":
        raise ValueError("Only USD supplier orders are supported")
    normalized: dict[str, object] = {
        "contractVersion": SUPPLIER_CONNECTOR_CONTRACT_VERSION,
        "connectorKind": connector_kind,
        "purchaseOrderID": purchase_order_id,
        "purchaseOrderNumber": supplier_connector_text(payload, "purchaseOrderNumber", maximum=120),
        "serviceCallID": service_call_id,
        "vendorName": supplier_connector_text(payload, "vendorName", maximum=160),
        "itemName": supplier_connector_text(payload, "itemName", maximum=200),
        "internalSKU": supplier_connector_text(payload, "internalSKU", maximum=120, required=False),
        "supplierPartNumber": supplier_connector_text(payload, "supplierPartNumber", maximum=120, required=False),
        "quantity": supplier_connector_amount(payload, "quantity", positive=True),
        "expectedUnitCost": supplier_connector_amount(payload, "expectedUnitCost"),
        "expectedShippingCost": supplier_connector_amount(payload, "expectedShippingCost"),
        "currencyCode": "USD",
        "supplierLocation": supplier_connector_text(payload, "supplierLocation", maximum=120, required=False),
        "priceAvailabilityCheckedAt": supplier_connector_timestamp(
            payload.get("priceAvailabilityCheckedAt"),
            "priceAvailabilityCheckedAt",
            required=False,
        ),
        "orderNotes": supplier_connector_text(payload, "orderNotes", maximum=500, required=False),
    }
    if normalized["supplierPartNumber"] is None and normalized["internalSKU"] is None:
        raise ValueError("Supplier order requires a supplier part number or internal SKU")
    return normalized


def validate_supplier_order_acceptance(
    response: object,
    request: dict[str, object],
    *,
    actor_email: str,
    idempotency_key: str,
) -> dict[str, object]:
    """Normalize an adapter result without forwarding its raw response to a client or log."""
    if not isinstance(response, dict):
        raise SupplierConnectorFailure("invalid-adapter-response", "The supplier returned an invalid acknowledgement.", outcome_unknown=True)
    try:
        external_order_id = supplier_connector_text(response, "externalOrderID", maximum=200)
        reference = supplier_connector_text(response, "reference", maximum=120)
        supplier_location = supplier_connector_text(response, "supplierLocation", maximum=120, required=False)
        confirmed_unit_cost = supplier_connector_amount(response, "confirmedUnitCost")
        confirmed_shipping_cost = supplier_connector_amount(response, "confirmedShippingCost")
        currency_code = supplier_connector_text(response, "currencyCode", maximum=3)
        if currency_code.upper() != "USD":
            raise ValueError("Invalid currencyCode")
        confirmed_at = supplier_connector_timestamp(response.get("confirmedAt"), "confirmedAt")
        checked_at = supplier_connector_timestamp(
            response.get("priceAvailabilityCheckedAt"),
            "priceAvailabilityCheckedAt",
        )
        confirmed_date = datetime.fromisoformat(confirmed_at)
        checked_date = datetime.fromisoformat(checked_at)
        now = datetime.now(timezone.utc)
        if confirmed_date > now + timedelta(minutes=5):
            raise ValueError("Invalid confirmedAt")
        if checked_date > confirmed_date + timedelta(minutes=5) or confirmed_date - checked_date > timedelta(hours=24):
            raise ValueError("Invalid priceAvailabilityCheckedAt")
    except ValueError as error:
        raise SupplierConnectorFailure(
            "invalid-adapter-response",
            "The supplier acknowledgement is incomplete or cannot be reconciled safely.",
            outcome_unknown=True,
        ) from error
    return {
        "contractVersion": request["contractVersion"],
        "purchaseOrderID": request["purchaseOrderID"],
        "purchaseOrderNumber": request["purchaseOrderNumber"],
        "connectorKind": request["connectorKind"],
        "externalOrderID": external_order_id,
        "reference": reference,
        "supplierLocation": supplier_location,
        "confirmedUnitCost": confirmed_unit_cost,
        "confirmedShippingCost": confirmed_shipping_cost,
        "currencyCode": "USD",
        "confirmedByEmail": normalize_email(actor_email),
        "confirmedAt": confirmed_at,
        "priceAvailabilityCheckedAt": checked_at,
        "idempotencyKey": idempotency_key,
    }


def db() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(DB_PATH)
    connection.row_factory = sqlite3.Row
    return connection


def path_is_within(path: Path, root: Path) -> bool:
    try:
        resolved_path = path.resolve()
        resolved_root = root.resolve()
    except OSError:
        return False
    return resolved_path == resolved_root or resolved_root in resolved_path.parents


def readiness_component(component_id: str, title: str, status: str, detail: str) -> dict[str, str]:
    return {"id": component_id, "title": title, "status": status, "detail": detail}


def database_readiness_component() -> dict[str, str]:
    try:
        with db() as connection:
            result = connection.execute("PRAGMA quick_check").fetchone()
            if result is None or str(result[0]).lower() != "ok":
                return readiness_component("database", "Database", "error", "SQLite integrity check did not pass.")
            connection.execute("BEGIN IMMEDIATE")
            connection.execute("ROLLBACK")
        return readiness_component("database", "Database", "ready", "SQLite is readable, writable, and internally consistent.")
    except sqlite3.Error:
        return readiness_component("database", "Database", "error", "SQLite is unavailable or not writable.")


def storage_readiness_component() -> dict[str, str]:
    try:
        STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(prefix=".gunnaire-readiness-", dir=STORAGE_ROOT, delete=True) as probe:
            probe.write(b"ready")
            probe.flush()
            os.fsync(probe.fileno())
        return readiness_component("storage", "Document Storage", "ready", "Shared document storage is readable and writable.")
    except OSError:
        return readiness_component("storage", "Document Storage", "error", "Shared document storage is unavailable or not writable.")


def persistent_data_readiness_component() -> dict[str, str]:
    configured = DATA_ROOT is not None and path_is_within(DB_PATH, DATA_ROOT) and path_is_within(STORAGE_ROOT, DATA_ROOT)
    if configured:
        return readiness_component("persistent-data", "Persistent Data", "ready", "Database and documents are rooted in the configured persistent data directory.")
    return readiness_component("persistent-data", "Persistent Data", "attention", "Configure one persistent data root for both the database and shared documents.")


def authentication_readiness_component() -> dict[str, str]:
    if AUTH_MODE == "google-id-token":
        if not APPLE_CLIENT_ID:
            return readiness_component("authentication", "Authentication", "error", "Configure the Sign in with Apple client identifier.")
        return readiness_component("authentication", "Authentication", "ready", "Google identity and verified Apple application sessions are active.")
    return readiness_component("authentication", "Authentication", "attention", "Shared API-token mode is for a physically controlled development server only.")


def customer_portal_readiness_component() -> dict[str, str]:
    if not CUSTOMER_PORTAL_ENABLED:
        return readiness_component(
            "customer-portal",
            "Customer Portal",
            "attention",
            "Customer portal links are disabled; complete public-route acceptance before enabling them.",
        )
    origin = customer_portal_origin()
    if origin is None:
        return readiness_component(
            "customer-portal",
            "Customer Portal",
            "error",
            "Configure one HTTPS origin with no credentials, path, query, or fragment.",
        )
    hostname = urlparse(origin).hostname or "configured host"
    return readiness_component(
        "customer-portal",
        "Customer Portal",
        "ready",
        f"Expiring capability links are restricted to HTTPS on {hostname}.",
    )


def quickbooks_readiness_component() -> dict[str, str]:
    if not qbo_is_configured() or not qbo_token_storage_is_configured():
        return readiness_component("quickbooks", "QuickBooks Bridge", "attention", "Configure Intuit credentials, redirect URI, and encrypted refresh-token storage.")
    try:
        with db() as connection:
            row = connection.execute(
                "SELECT realm_id, environment, refresh_token_ciphertext, client_id_fingerprint FROM qbo_connections WHERE id = 1"
            ).fetchone()
    except sqlite3.Error:
        return readiness_component("quickbooks", "QuickBooks Bridge", "error", "QuickBooks connection storage is unavailable.")
    if row is None:
        return readiness_component("quickbooks", "QuickBooks Bridge", "attention", "Bridge configuration is present; authorize the approved QuickBooks company realm.")
    expected_fingerprint = hashlib.sha256(QBO_CLIENT_ID.encode("utf-8")).hexdigest()
    if row["environment"] != QBO_ENVIRONMENT or row["client_id_fingerprint"] != expected_fingerprint:
        return readiness_component("quickbooks", "QuickBooks Bridge", "error", "Saved QuickBooks authorization does not match this client or environment.")
    if not decrypt_qbo_refresh_token(row["refresh_token_ciphertext"]):
        return readiness_component("quickbooks", "QuickBooks Bridge", "error", "Saved QuickBooks authorization cannot be decrypted; reconnect safely.")
    return readiness_component("quickbooks", "QuickBooks Bridge", "ready", f"Encrypted authorization is available for the {QBO_ENVIRONMENT} company realm.")


def quickbooks_accounting_configuration_readiness_component() -> dict[str, str]:
    context = current_qbo_connection_context()
    if context is None:
        return readiness_component(
            "quickbooks-accounting-config",
            "QuickBooks Accounting Mappings",
            "attention",
            "Authorize the approved QuickBooks company before choosing accounting mappings.",
        )
    realm_id, environment = context
    try:
        with db() as connection:
            row = connection.execute(
                "SELECT * FROM qbo_accounting_config WHERE realm_id = ? AND environment = ?",
                (realm_id, environment),
            ).fetchone()
    except sqlite3.Error:
        return readiness_component(
            "quickbooks-accounting-config",
            "QuickBooks Accounting Mappings",
            "error",
            "Realm-specific accounting mapping storage is unavailable.",
        )
    if row is None:
        return readiness_component(
            "quickbooks-accounting-config",
            "QuickBooks Accounting Mappings",
            "attention",
            "Choose the default sales item, income, expense, bank, and credit-card accounts in GunnAire Ops.",
        )
    return readiness_component(
        "quickbooks-accounting-config",
        "QuickBooks Accounting Mappings",
        "ready",
        f"Accounting defaults are bound to the authorized {environment} company realm.",
    )


def quickbooks_webhook_readiness_component() -> dict[str, str]:
    if not QBO_WEBHOOK_VERIFIER_TOKEN:
        return readiness_component(
            "quickbooks-webhooks",
            "QuickBooks Change Alerts",
            "attention",
            "Configure the Intuit webhook verifier token before accepting change notifications.",
        )
    realm_id = current_qbo_realm_id()
    if realm_id is None:
        return readiness_component(
            "quickbooks-webhooks",
            "QuickBooks Change Alerts",
            "attention",
            "Authorize the approved QuickBooks company before enabling its webhook subscription.",
        )
    try:
        with db() as connection:
            row = connection.execute(
                "SELECT received_at FROM qbo_webhook_events WHERE realm_id = ? ORDER BY received_at DESC LIMIT 1",
                (realm_id,),
            ).fetchone()
    except sqlite3.Error:
        return readiness_component(
            "quickbooks-webhooks",
            "QuickBooks Change Alerts",
            "error",
            "QuickBooks change-event storage is unavailable.",
        )
    if row is None:
        return readiness_component(
            "quickbooks-webhooks",
            "QuickBooks Change Alerts",
            "attention",
            "Receiver is configured; send and verify an Intuit test event before relying on change alerts.",
        )
    return readiness_component(
        "quickbooks-webhooks",
        "QuickBooks Change Alerts",
        "ready",
        "A signed event has been received for the authorized company realm.",
    )


def push_notification_readiness_component(now: datetime | None = None) -> dict[str, str]:
    checked_at = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    if not apns_configuration_is_present():
        return readiness_component(
            "push-notifications",
            "Staff Push Notifications",
            "attention",
            "Configure encrypted device-token storage and the APNs team, key, private key, and topic.",
        )
    if push_token_store() is None:
        return readiness_component(
            "push-notifications",
            "Staff Push Notifications",
            "error",
            "The configured push-device encryption key is invalid.",
        )
    try:
        apns_private_key()
    except ValueError:
        return readiness_component(
            "push-notifications",
            "Staff Push Notifications",
            "error",
            "The APNs signing configuration is invalid; replace it through the deployment secret manager.",
        )
    if not apns_provider_dependency_is_available():
        return readiness_component(
            "push-notifications",
            "Staff Push Notifications",
            "error",
            "The HTTP/2 APNs provider dependency is unavailable on this server.",
        )
    try:
        with db() as connection:
            active_devices = connection.execute(
                "SELECT token_ciphertext FROM push_devices WHERE deactivated_at IS NULL"
            ).fetchall()
            pending = connection.execute(
                """
                SELECT COUNT(*) AS total, MIN(created_at) AS oldest,
                       MAX(CASE WHEN last_error_code IN (
                           'ExpiredProviderToken', 'InvalidProviderToken', 'MissingProviderToken',
                           'Forbidden', 'BadEnvironmentKeyIdInToken', 'UnrelatedKeyIdInToken'
                       ) THEN 1 ELSE 0 END) AS credential_error
                FROM push_deliveries WHERE status = 'pending'
                """
            ).fetchone()
            recent_failures = connection.execute(
                """
                SELECT COUNT(*) AS total FROM push_deliveries
                WHERE status = 'failed' AND updated_at >= ?
                """,
                ((checked_at - timedelta(hours=24)).isoformat(),),
            ).fetchone()
    except sqlite3.Error:
        return readiness_component(
            "push-notifications",
            "Staff Push Notifications",
            "error",
            "Push registration or delivery storage is unavailable.",
        )
    if any(decrypt_push_device_token(str(row["token_ciphertext"])) is None for row in active_devices):
        return readiness_component(
            "push-notifications",
            "Staff Push Notifications",
            "error",
            "One or more active APNs device registrations cannot be decrypted.",
        )
    if pending is not None and bool(pending["credential_error"]):
        return readiness_component(
            "push-notifications",
            "Staff Push Notifications",
            "error",
            "APNs rejected the provider credentials; queued staff alerts were retained for recovery.",
        )
    pending_total = int(pending["total"] or 0) if pending is not None else 0
    if pending_total and isinstance(pending["oldest"], str):
        try:
            oldest = datetime.fromisoformat(str(pending["oldest"]).replace("Z", "+00:00"))
            if oldest.tzinfo is not None and checked_at - oldest.astimezone(timezone.utc) > timedelta(minutes=30):
                return readiness_component(
                    "push-notifications",
                    "Staff Push Notifications",
                    "attention",
                    f"{pending_total} staff alert{'s are' if pending_total != 1 else ' is'} waiting more than 30 minutes for delivery.",
                )
        except ValueError:
            return readiness_component(
                "push-notifications",
                "Staff Push Notifications",
                "error",
                "A queued staff alert has invalid delivery timing metadata.",
            )
    failed_total = int(recent_failures["total"] or 0) if recent_failures is not None else 0
    if failed_total:
        return readiness_component(
            "push-notifications",
            "Staff Push Notifications",
            "attention",
            f"{failed_total} staff alert{'s need' if failed_total != 1 else ' needs'} review after a permanent APNs failure in the last 24 hours.",
        )
    active_total = len(active_devices)
    if pending_total:
        detail = f"APNs is configured for {active_total} active device{'s' if active_total != 1 else ''}; {pending_total} recent alert{'s are' if pending_total != 1 else ' is'} queued."
    elif active_total:
        detail = f"APNs is configured and {active_total} active device{'s are' if active_total != 1 else ' is'} registered."
    else:
        detail = "APNs is configured; staff can opt in from GunnAire Ops Settings."
    return readiness_component(
        "push-notifications",
        "Staff Push Notifications",
        "ready",
        detail,
    )


def backup_readiness_component(now: datetime | None = None) -> dict[str, str]:
    checked_at = now or datetime.now(timezone.utc)
    try:
        if not BACKUP_STATUS_PATH.is_file() or BACKUP_STATUS_PATH.stat().st_size > 64 * 1024:
            raise ValueError("missing backup status")
        payload = json.loads(BACKUP_STATUS_PATH.read_text(encoding="utf-8"))
        verified_at_raw = payload.get("verifiedAt") if isinstance(payload, dict) else None
        artifact_id = payload.get("artifactID") if isinstance(payload, dict) else None
        if not isinstance(verified_at_raw, str) or not isinstance(artifact_id, str):
            raise ValueError("invalid backup status")
        verified_at = datetime.fromisoformat(verified_at_raw.replace("Z", "+00:00"))
        if verified_at.tzinfo is None:
            raise ValueError("backup status lacks timezone")
        age_hours = max((checked_at - verified_at.astimezone(timezone.utc)).total_seconds() / 3600, 0)
        if age_hours > BACKUP_MAX_AGE_HOURS:
            return readiness_component("backup", "Verified Backup", "attention", f"Latest verified backup is {age_hours:.1f} hours old; target is {BACKUP_MAX_AGE_HOURS} hours or less.")
        return readiness_component("backup", "Verified Backup", "ready", f"Backup {artifact_id[:12]} was verified {age_hours:.1f} hours ago; retain a copy off-host.")
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return readiness_component("backup", "Verified Backup", "attention", "No recent verified backup record is available; create and retain an off-host backup.")


def backend_readiness_snapshot(now: datetime | None = None) -> dict[str, object]:
    components = [
        persistent_data_readiness_component(),
        database_readiness_component(),
        storage_readiness_component(),
        authentication_readiness_component(),
        customer_portal_readiness_component(),
        quickbooks_readiness_component(),
        quickbooks_accounting_configuration_readiness_component(),
        quickbooks_webhook_readiness_component(),
        push_notification_readiness_component(now=now),
        backup_readiness_component(now=now),
    ]
    overall = "ready" if all(component["status"] == "ready" for component in components) else "attention"
    return {
        "status": overall,
        "serviceVersion": SERVICE_VERSION,
        "checkedAt": (now or datetime.now(timezone.utc)).isoformat(),
        "components": components,
    }


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
            CREATE TABLE IF NOT EXISTS auth_sessions (
                id TEXT PRIMARY KEY,
                token_hash TEXT NOT NULL UNIQUE,
                email TEXT NOT NULL,
                provider TEXT NOT NULL,
                provider_subject TEXT NOT NULL,
                created_at TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                last_used_at TEXT NOT NULL,
                revoked_at TEXT,
                FOREIGN KEY(email) REFERENCES users(email)
            )
            """
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS auth_sessions_active_token ON auth_sessions(token_hash, expires_at, revoked_at)"
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS apple_identities (
                provider_subject TEXT PRIMARY KEY,
                email TEXT NOT NULL,
                credential_state TEXT NOT NULL,
                relay_enabled INTEGER,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_event_at TEXT,
                FOREIGN KEY(email) REFERENCES users(email)
            )
            """
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS apple_identities_email ON apple_identities(email)"
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS apple_account_events (
                jti TEXT PRIMARY KEY,
                event_type TEXT NOT NULL,
                subject_hash TEXT NOT NULL,
                event_time TEXT NOT NULL,
                received_at TEXT NOT NULL,
                matched_email TEXT,
                sessions_revoked INTEGER NOT NULL DEFAULT 0,
                devices_deactivated INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS apple_account_events_received ON apple_account_events(received_at)"
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS push_devices (
                id TEXT PRIMARY KEY,
                installation_id TEXT NOT NULL UNIQUE,
                token_ciphertext TEXT NOT NULL,
                token_fingerprint TEXT NOT NULL UNIQUE,
                email TEXT NOT NULL,
                auth_session_id TEXT NOT NULL,
                platform TEXT NOT NULL,
                environment TEXT NOT NULL,
                bundle_id TEXT NOT NULL,
                app_version TEXT,
                app_build TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                deactivated_at TEXT,
                FOREIGN KEY(email) REFERENCES users(email),
                FOREIGN KEY(auth_session_id) REFERENCES auth_sessions(id)
            )
            """
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS push_devices_recipient_active ON push_devices(email, deactivated_at)"
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS push_devices_session_active ON push_devices(auth_session_id, deactivated_at)"
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS push_deliveries (
                id TEXT PRIMARY KEY,
                event_key TEXT NOT NULL,
                device_id TEXT NOT NULL,
                recipient_email TEXT NOT NULL,
                category TEXT NOT NULL,
                route TEXT NOT NULL,
                record_id TEXT NOT NULL,
                status TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_at TEXT NOT NULL,
                last_attempt_at TEXT,
                last_error_code TEXT,
                apns_id TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                sent_at TEXT,
                UNIQUE(event_key, device_id),
                FOREIGN KEY(device_id) REFERENCES push_devices(id)
            )
            """
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS push_deliveries_pending ON push_deliveries(status, next_attempt_at, created_at)"
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
                maintenance_contract_id TEXT,
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
        ensure_column(connection, "documents", "maintenance_contract_id", "TEXT")
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
                cancelled_by TEXT,
                collected_amount REAL NOT NULL DEFAULT 0,
                completed_at TEXT,
                completed_by TEXT,
                completion_payment_id TEXT
            )
            """
        )
        ensure_column(connection, "field_payment_assignments", "collected_amount", "REAL NOT NULL DEFAULT 0")
        ensure_column(connection, "field_payment_assignments", "completed_at", "TEXT")
        ensure_column(connection, "field_payment_assignments", "completed_by", "TEXT")
        ensure_column(connection, "field_payment_assignments", "completion_payment_id", "TEXT")
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS customer_communications (
                id TEXT PRIMARY KEY,
                customer_name TEXT NOT NULL,
                customer_email TEXT,
                service_call_id TEXT,
                invoice_id TEXT,
                estimate_id TEXT,
                maintenance_contract_id TEXT,
                channel TEXT NOT NULL,
                direction TEXT NOT NULL,
                recipient TEXT NOT NULL,
                subject TEXT NOT NULL,
                delivery_status TEXT NOT NULL,
                workflow TEXT NOT NULL DEFAULT 'general',
                template_version TEXT NOT NULL DEFAULT 'general-v1',
                actor_email TEXT,
                consent_snapshot_json TEXT,
                provider_status_detail TEXT,
                delivered_at TEXT,
                attachment_file_names_json TEXT,
                provider_message_id TEXT,
                occurred_at TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """
        )
        ensure_column(connection, "customer_communications", "maintenance_contract_id", "TEXT")
        ensure_column(connection, "customer_communications", "workflow", "TEXT NOT NULL DEFAULT 'general'")
        ensure_column(connection, "customer_communications", "template_version", "TEXT NOT NULL DEFAULT 'general-v1'")
        ensure_column(connection, "customer_communications", "actor_email", "TEXT")
        ensure_column(connection, "customer_communications", "consent_snapshot_json", "TEXT")
        ensure_column(connection, "customer_communications", "provider_status_detail", "TEXT")
        ensure_column(connection, "customer_communications", "delivered_at", "TEXT")
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
                opened_count INTEGER NOT NULL DEFAULT 0,
                last_opened_at TEXT,
                created_at TEXT NOT NULL,
                created_by TEXT NOT NULL
            )
            """
        )
        ensure_column(connection, "customer_portal_links", "opened_count", "INTEGER NOT NULL DEFAULT 0")
        ensure_column(connection, "customer_portal_links", "last_opened_at", "TEXT")
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
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS qbo_accounting_config (
                realm_id TEXT NOT NULL,
                environment TEXT NOT NULL,
                default_sales_item_ref TEXT NOT NULL,
                default_sales_item_name TEXT NOT NULL,
                default_sales_item_type TEXT NOT NULL,
                default_income_account_ref TEXT NOT NULL,
                default_income_account_name TEXT NOT NULL,
                default_income_account_type TEXT NOT NULL,
                default_expense_account_ref TEXT NOT NULL,
                default_expense_account_name TEXT NOT NULL,
                default_expense_account_type TEXT NOT NULL,
                default_bank_account_ref TEXT NOT NULL,
                default_bank_account_name TEXT NOT NULL,
                default_bank_account_type TEXT NOT NULL,
                default_credit_card_account_ref TEXT NOT NULL,
                default_credit_card_account_name TEXT NOT NULL,
                default_credit_card_account_type TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                updated_by TEXT NOT NULL,
                PRIMARY KEY(realm_id, environment)
            )
            """
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS qbo_webhook_events (
                event_id TEXT PRIMARY KEY,
                realm_id TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                operation TEXT NOT NULL,
                occurred_at TEXT NOT NULL,
                received_at TEXT NOT NULL,
                acknowledged_at TEXT,
                acknowledged_by TEXT
            )
            """
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS qbo_webhook_events_realm_pending ON qbo_webhook_events(realm_id, acknowledged_at, received_at)"
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS supplier_order_attempts (
                idempotency_key TEXT PRIMARY KEY,
                request_hash TEXT NOT NULL,
                purchase_order_id TEXT NOT NULL,
                purchase_order_number TEXT NOT NULL,
                connector_kind TEXT NOT NULL,
                actor_email TEXT NOT NULL,
                request_json TEXT NOT NULL,
                status TEXT NOT NULL,
                acceptance_json TEXT,
                error_code TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS supplier_order_attempts_order ON supplier_order_attempts(purchase_order_id, created_at)"
        )
        connection.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS supplier_order_attempts_one_acceptance ON supplier_order_attempts(purchase_order_id) WHERE status = 'accepted'"
        )
        connection.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS supplier_order_attempts_one_active ON supplier_order_attempts(purchase_order_id) WHERE status IN ('submitting', 'unknown', 'accepted')"
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
        "collectedAmount": row["collected_amount"],
        "completedAt": row["completed_at"],
        "completedBy": row["completed_by"],
        "completionPaymentID": row["completion_payment_id"],
    }


def push_device_record(row: sqlite3.Row) -> dict[str, object]:
    """Return operational metadata only; tokens and fingerprints stay server-side."""
    return {
        "installationID": row["installation_id"],
        "platform": row["platform"],
        "environment": row["environment"],
        "bundleID": row["bundle_id"],
        "appVersion": row["app_version"],
        "appBuild": row["app_build"],
        "registeredAt": row["created_at"],
        "updatedAt": row["updated_at"],
        "isActive": row["deactivated_at"] is None,
    }


def deactivate_push_devices(
    connection: sqlite3.Connection,
    *,
    device_id: str | None = None,
    session_id: str | None = None,
    email: str | None = None,
    installation_id: str | None = None,
) -> int:
    clauses = ["deactivated_at IS NULL"]
    parameters: list[object] = []
    if device_id is not None:
        clauses.append("id = ?")
        parameters.append(device_id)
    if session_id is not None:
        clauses.append("auth_session_id = ?")
        parameters.append(session_id)
    if email is not None:
        clauses.append("email = ?")
        parameters.append(normalize_email(email))
    if installation_id is not None:
        clauses.append("installation_id = ?")
        parameters.append(installation_id)
    if len(clauses) == 1:
        raise ValueError("Push-device deactivation requires a bounded owner")
    where_clause = " AND ".join(clauses)
    rows = connection.execute(
        f"SELECT id FROM push_devices WHERE {where_clause}",
        tuple(parameters),
    ).fetchall()
    if not rows:
        return 0
    now = utc_now()
    device_ids = [str(row["id"]) for row in rows]
    placeholders = ",".join("?" for _ in device_ids)
    connection.execute(
        f"UPDATE push_devices SET deactivated_at = ?, updated_at = ? WHERE id IN ({placeholders})",
        (now, now, *device_ids),
    )
    connection.execute(
        f"""
        UPDATE push_deliveries
        SET status = 'suppressed', updated_at = ?, last_error_code = 'DeviceDeactivated'
        WHERE device_id IN ({placeholders}) AND status = 'pending'
        """,
        (now, *device_ids),
    )
    return len(device_ids)


def process_apple_account_notification(event: dict[str, object]) -> dict[str, object]:
    """Apply one verified Apple event idempotently without retaining its JWS or relay address."""
    event_id = str(event["id"])
    event_type = str(event["type"])
    provider_subject = str(event["providerSubject"])
    event_time = str(event["eventTime"])
    subject_hash = hashlib.sha256(provider_subject.encode("utf-8")).hexdigest()
    received_at = utc_now()
    sessions_revoked = 0
    devices_deactivated = 0
    matched_email: str | None = None
    with db() as connection:
        inserted = connection.execute(
            """
            INSERT OR IGNORE INTO apple_account_events(
                jti, event_type, subject_hash, event_time, received_at,
                matched_email, sessions_revoked, devices_deactivated
            ) VALUES (?, ?, ?, ?, ?, NULL, 0, 0)
            """,
            (event_id, event_type, subject_hash, event_time, received_at),
        ).rowcount
        if inserted == 0:
            return {"accepted": True, "idempotentReplay": True}

        identity = connection.execute(
            "SELECT * FROM apple_identities WHERE provider_subject = ?",
            (provider_subject,),
        ).fetchone()
        identity_was_created_from_session = False
        session_rows = connection.execute(
            """
            SELECT id, email, revoked_at FROM auth_sessions
            WHERE provider = 'apple' AND provider_subject = ?
            """,
            (provider_subject,),
        ).fetchall()
        session_emails = {
            normalize_email(str(row["email"]))
            for row in session_rows
            if is_valid_email(normalize_email(str(row["email"])))
        }
        if identity is not None:
            matched_email = normalize_email(str(identity["email"]))
        elif len(session_emails) == 1:
            matched_email = next(iter(session_emails))
            connection.execute(
                """
                INSERT INTO apple_identities(
                    provider_subject, email, credential_state, relay_enabled,
                    created_at, updated_at, last_event_at
                ) VALUES (?, ?, 'authorized', NULL, ?, ?, NULL)
                """,
                (provider_subject, matched_email, received_at, received_at),
            )
            identity = connection.execute(
                "SELECT * FROM apple_identities WHERE provider_subject = ?",
                (provider_subject,),
            ).fetchone()
            identity_was_created_from_session = True

        apply_identity_event = identity is not None
        if identity is not None and not identity_was_created_from_session:
            latest_identity_change: datetime | None = None
            for raw_value in (identity["updated_at"], identity["last_event_at"]):
                if not isinstance(raw_value, str) or not raw_value:
                    continue
                try:
                    parsed_value = datetime.fromisoformat(raw_value.replace("Z", "+00:00"))
                except ValueError:
                    continue
                if parsed_value.tzinfo is None:
                    continue
                parsed_value = parsed_value.astimezone(timezone.utc)
                if latest_identity_change is None or parsed_value > latest_identity_change:
                    latest_identity_change = parsed_value
            try:
                parsed_event_time = datetime.fromisoformat(event_time.replace("Z", "+00:00"))
            except ValueError:
                parsed_event_time = None
            if (
                parsed_event_time is None
                or parsed_event_time.tzinfo is None
                or (
                    latest_identity_change is not None
                    and parsed_event_time.astimezone(timezone.utc)
                    < latest_identity_change.replace(microsecond=0)
                )
            ):
                apply_identity_event = False

        if apply_identity_event:
            if event_type in {"consent-revoked", "account-deleted"}:
                connection.execute(
                    """
                    UPDATE apple_identities
                    SET credential_state = ?, updated_at = ?, last_event_at = ?
                    WHERE provider_subject = ?
                    """,
                    (event_type, received_at, event_time, provider_subject),
                )
            else:
                connection.execute(
                    """
                    UPDATE apple_identities
                    SET relay_enabled = ?, updated_at = ?, last_event_at = ?
                    WHERE provider_subject = ?
                    """,
                    (1 if event_type == "email-enabled" else 0, received_at, event_time, provider_subject),
                )

        if (
            event_type in {"consent-revoked", "account-deleted"}
            and (identity is None or apply_identity_event)
        ):
            active_session_ids = [
                str(row["id"])
                for row in session_rows
                if row["revoked_at"] is None
            ]
            if active_session_ids:
                placeholders = ",".join("?" for _ in active_session_ids)
                sessions_revoked = connection.execute(
                    f"""
                    UPDATE auth_sessions SET revoked_at = ?
                    WHERE id IN ({placeholders}) AND revoked_at IS NULL
                    """,
                    (received_at, *active_session_ids),
                ).rowcount
                for session_id in active_session_ids:
                    devices_deactivated += deactivate_push_devices(
                        connection,
                        session_id=session_id,
                    )

        connection.execute(
            """
            UPDATE apple_account_events
            SET matched_email = ?, sessions_revoked = ?, devices_deactivated = ?
            WHERE jti = ?
            """,
            (matched_email, sessions_revoked, devices_deactivated, event_id),
        )
        connection.execute(
            """
            INSERT INTO audit_events(
                id, occurred_at, actor_email, action, subject_type, subject_id
            ) VALUES (?, ?, 'apple-notification@appleid.apple.com', ?, 'apple-identity', ?)
            """,
            (str(uuid.uuid4()), received_at, event_type, subject_hash[:24]),
        )
    return {"accepted": True, "idempotentReplay": False}


def queue_staff_push_event(
    *,
    event_key: str,
    recipient_email: str,
    category: str,
    route: str,
    record_id: str,
) -> int:
    """Create one durable delivery per active device without customer/payment content."""
    email = normalize_email(recipient_email)
    try:
        normalized_record_id = str(uuid.UUID(record_id))
    except ValueError as error:
        raise ValueError("Invalid staff notification event") from error
    if (
        not re.fullmatch(r"[A-Za-z0-9:_-]{1,160}", event_key)
        or not is_valid_email(email)
        or category not in {"field-payment-assignment"}
        or route not in {"paymentCollection"}
    ):
        raise ValueError("Invalid staff notification event")
    now = utc_now()
    queued = 0
    with db() as connection:
        devices = connection.execute(
            """
            SELECT push_devices.id
            FROM push_devices
            INNER JOIN users ON users.email = push_devices.email
            INNER JOIN auth_sessions ON auth_sessions.id = push_devices.auth_session_id
            WHERE push_devices.email = ?
              AND push_devices.deactivated_at IS NULL
              AND users.is_active = 1
              AND auth_sessions.revoked_at IS NULL
              AND auth_sessions.expires_at > ?
            """,
            (email, now),
        ).fetchall()
        for device in devices:
            queued += connection.execute(
                """
                INSERT INTO push_deliveries(
                    id, event_key, device_id, recipient_email, category, route,
                    record_id, status, attempts, next_attempt_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?, ?)
                ON CONFLICT(event_key, device_id) DO NOTHING
                """,
                (
                    str(uuid.uuid4()), event_key, device["id"], email, category,
                    route, normalized_record_id, now, now, now,
                ),
            ).rowcount
    if queued:
        PUSH_DELIVERY_WAKE_EVENT.set()
    return queued


def staff_push_payload(row: sqlite3.Row) -> dict[str, object]:
    """Build a generic preview; customer names, addresses, and balances are excluded."""
    return {
        "aps": {
            "alert": {
                "title": "New collection task",
                "body": "Open GunnAire Ops to review an assigned invoice.",
            },
            "sound": "default",
        },
        "gunnaire": {
            "version": 1,
            "eventID": row["event_key"],
            "route": row["route"],
            "recordID": row["record_id"],
        },
    }


PERMANENT_APNS_ERROR_REASONS = {
    "BadDeviceToken",
    "DeviceTokenNotForTopic",
    "ExpiredToken",
    "Unregistered",
}
NONRETRYABLE_APNS_ERROR_REASONS = {
    "BadCollapseId",
    "BadExpirationDate",
    "BadMessageId",
    "BadPath",
    "MethodNotAllowed",
    "PayloadTooLarge",
}


def deliver_pending_pushes(
    *,
    sender=send_apns_request,
    now: datetime | None = None,
    limit: int | None = None,
) -> int:
    """Attempt due deliveries once; retries remain durable and assignment creation never waits."""
    if not apns_configuration_is_present() or push_token_store() is None:
        return 0
    checked_at = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    attempted = 0
    if not PUSH_DELIVERY_LOCK.acquire(blocking=False):
        return 0
    try:
        with db() as connection:
            rows = connection.execute(
                """
                SELECT push_deliveries.*, push_devices.token_ciphertext,
                       push_devices.environment, push_devices.deactivated_at
                FROM push_deliveries
                INNER JOIN push_devices ON push_devices.id = push_deliveries.device_id
                WHERE push_deliveries.status = 'pending'
                  AND push_deliveries.next_attempt_at <= ?
                  AND push_devices.deactivated_at IS NULL
                ORDER BY push_deliveries.created_at ASC
                LIMIT ?
                """,
                (checked_at.isoformat(), limit or APNS_DELIVERY_BATCH_SIZE),
            ).fetchall()

        for row in rows:
            token = decrypt_push_device_token(str(row["token_ciphertext"]))
            if token is None:
                with db() as connection:
                    connection.execute(
                        """
                        UPDATE push_deliveries
                        SET status = 'failed', attempts = attempts + 1,
                            last_attempt_at = ?, last_error_code = 'TokenDecryptFailed', updated_at = ?
                        WHERE id = ? AND status = 'pending'
                        """,
                        (checked_at.isoformat(), checked_at.isoformat(), row["id"]),
                    )
                    deactivate_push_devices(connection, device_id=str(row["device_id"]))
                continue
            collapse_id = hashlib.sha256(str(row["event_key"]).encode("utf-8")).hexdigest()[:32]
            try:
                status_code, reason, apns_id = sender(
                    device_token=token,
                    environment=str(row["environment"]),
                    payload=staff_push_payload(row),
                    collapse_id=collapse_id,
                )
            except Exception:
                status_code, reason, apns_id = HTTPStatus.SERVICE_UNAVAILABLE, "ProviderConnectionFailed", None
            attempted += 1
            attempt_count = int(row["attempts"]) + 1
            attempted_at = checked_at.isoformat()
            with db() as connection:
                if 200 <= int(status_code) < 300:
                    connection.execute(
                        """
                        UPDATE push_deliveries
                        SET status = 'sent', attempts = ?, last_attempt_at = ?,
                            last_error_code = NULL, apns_id = ?, sent_at = ?, updated_at = ?
                        WHERE id = ? AND status = 'pending'
                        """,
                        (attempt_count, attempted_at, apns_id, attempted_at, attempted_at, row["id"]),
                    )
                    continue

                error_code = reason or f"HTTP{int(status_code)}"
                if reason in PERMANENT_APNS_ERROR_REASONS or int(status_code) == HTTPStatus.GONE:
                    connection.execute(
                        """
                        UPDATE push_deliveries
                        SET status = 'failed', attempts = ?, last_attempt_at = ?,
                            last_error_code = ?, updated_at = ?
                        WHERE id = ? AND status = 'pending'
                        """,
                        (attempt_count, attempted_at, error_code, attempted_at, row["id"]),
                    )
                    deactivate_push_devices(connection, device_id=str(row["device_id"]))
                    continue

                nonretryable = reason in NONRETRYABLE_APNS_ERROR_REASONS or int(status_code) in {
                    HTTPStatus.BAD_REQUEST,
                    HTTPStatus.NOT_FOUND,
                    HTTPStatus.METHOD_NOT_ALLOWED,
                    HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                }
                if nonretryable or attempt_count >= 12:
                    connection.execute(
                        """
                        UPDATE push_deliveries
                        SET status = 'failed', attempts = ?, last_attempt_at = ?,
                            last_error_code = ?, updated_at = ?
                        WHERE id = ? AND status = 'pending'
                        """,
                        (attempt_count, attempted_at, error_code, attempted_at, row["id"]),
                    )
                    continue

                if int(status_code) == HTTPStatus.TOO_MANY_REQUESTS:
                    delay_seconds = min(60 * (2 ** min(attempt_count - 1, 4)), 15 * 60)
                else:
                    # Apple recommends delaying 5xx retries; credential/configuration
                    # corrections use the same bounded queue rather than dropping work.
                    delay_seconds = 15 * 60
                retry_at = (checked_at + timedelta(seconds=delay_seconds)).isoformat()
                connection.execute(
                    """
                    UPDATE push_deliveries
                    SET attempts = ?, last_attempt_at = ?, last_error_code = ?,
                        next_attempt_at = ?, updated_at = ?
                    WHERE id = ? AND status = 'pending'
                    """,
                    (attempt_count, attempted_at, error_code, retry_at, attempted_at, row["id"]),
                )
    finally:
        PUSH_DELIVERY_LOCK.release()
    return attempted


def push_delivery_worker() -> None:
    while True:
        PUSH_DELIVERY_WAKE_EVENT.wait(timeout=APNS_WORKER_INTERVAL_SECONDS)
        PUSH_DELIVERY_WAKE_EVENT.clear()
        try:
            deliver_pending_pushes()
        except Exception:
            # Readiness reports the durable backlog. The worker never terminates
            # because a provider or local database attempt failed transiently.
            continue


def start_push_delivery_worker() -> threading.Thread:
    worker = threading.Thread(target=push_delivery_worker, name="gunnaire-apns-worker", daemon=True)
    worker.start()
    return worker


def reconcile_field_payment_assignments(
    connection: sqlite3.Connection,
    *,
    invoice_id: str | None,
    actor_email: str,
    actor_role: object,
    payment_id: str,
    occurred_at: str,
) -> list[tuple[str, str]]:
    """Advance only authorized active tasks from durable payment records.

    A field technician may affect only their own assignment. Office collectors
    may close the active task because the invoice was collected centrally. The
    total is recomputed from idempotent payment rows, so retries never double
    count a partial collection.
    """
    if not invoice_id or not actor_email:
        return []

    query = """
        SELECT * FROM field_payment_assignments
        WHERE invoice_id = ? AND status IN ('pending', 'accepted')
    """
    parameters: tuple[object, ...] = (invoice_id,)
    if actor_role == "Field Technician":
        query += " AND assigned_to = ?"
        parameters += (actor_email,)

    changes: list[tuple[str, str]] = []
    for assignment in connection.execute(query, parameters).fetchall():
        payment_query = """
            SELECT COALESCE(SUM(amount), 0) AS collected_amount
            FROM payment_collections
            WHERE invoice_id = ? AND created_at >= ?
        """
        payment_parameters: tuple[object, ...] = (invoice_id, assignment["created_at"])
        if actor_role == "Field Technician":
            payment_query += " AND collected_by = ?"
            payment_parameters += (actor_email,)
        total = float(connection.execute(payment_query, payment_parameters).fetchone()["collected_amount"] or 0)
        completed = total + 0.0001 >= float(assignment["amount"])
        next_status = "completed" if completed else "accepted"
        connection.execute(
            """
            UPDATE field_payment_assignments
            SET status = ?, collected_amount = ?,
                accepted_at = COALESCE(accepted_at, ?),
                completed_at = CASE WHEN ? THEN COALESCE(completed_at, ?) ELSE completed_at END,
                completed_by = CASE WHEN ? THEN COALESCE(completed_by, ?) ELSE completed_by END,
                completion_payment_id = CASE WHEN ? THEN COALESCE(completion_payment_id, ?) ELSE completion_payment_id END
            WHERE id = ?
            """,
            (
                next_status,
                total,
                occurred_at,
                completed,
                occurred_at,
                completed,
                actor_email,
                completed,
                payment_id,
                assignment["id"],
            ),
        )
        changes.append((assignment["id"], next_status))
    return changes


def document_record(row: sqlite3.Row) -> dict[str, object]:
    return {
        "id": row["id"],
        "filename": row["filename"],
        "contentType": row["content_type"],
        "kind": row["kind"],
        "serviceCallID": row["service_call_id"],
        "invoiceID": row["invoice_id"],
        "estimateID": row["estimate_id"],
        "maintenanceContractID": row["maintenance_contract_id"],
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
        "credit", "statement", "transaction", "maintenance_agreement",
    }
    kind = str(row["kind"] or "").strip().lower()
    return bool(
        row["invoice_id"] or row["estimate_id"] or
        row["maintenance_contract_id"] or kind in financial_kinds
    )


def document_is_maintenance_agreement(row: sqlite3.Row) -> bool:
    return bool(
        row["maintenance_contract_id"] or
        str(row["kind"] or "").strip().lower() == "maintenance_agreement"
    )


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
        "workflow": row["workflow"],
        "templateVersion": row["template_version"],
        "actorEmail": row["actor_email"],
        "consentSnapshot": json.loads(row["consent_snapshot_json"]) if row["consent_snapshot_json"] else None,
        "providerStatusDetail": row["provider_status_detail"],
        "deliveredAt": row["delivered_at"],
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
        "openedCount": max(int(row["opened_count"] or 0), 0),
        "lastOpenedAt": row["last_opened_at"],
        "createdAt": row["created_at"],
        "createdBy": row["created_by"],
    }


def public_service_request_record(row: sqlite3.Row) -> dict[str, object]:
    return {
        "id": row["id"], "customerName": row["customer_name"], "phone": row["phone"],
        "email": row["email"], "address": row["address"],
        "requestedServiceType": row["requested_service_type"], "urgency": row["urgency"],
        "summary": row["summary"], "preferredDate": row["preferred_date"],
        "source": "website", "createdAt": row["created_at"],
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


def qbo_webhook_event_record(row: sqlite3.Row) -> dict[str, object]:
    """Return only reconciliation metadata; webhook data and realm IDs stay server-side."""
    return {
        "id": row["event_id"],
        "entityType": row["entity_type"],
        "entityID": row["entity_id"],
        "operation": row["operation"],
        "occurredAt": row["occurred_at"],
        "receivedAt": row["received_at"],
    }


def qbo_accounting_configuration_record(row: sqlite3.Row) -> dict[str, object]:
    return {
        "realmID": row["realm_id"],
        "environment": row["environment"],
        "defaultSalesItemRef": row["default_sales_item_ref"],
        "defaultSalesItemName": row["default_sales_item_name"],
        "defaultSalesItemType": row["default_sales_item_type"],
        "defaultIncomeAccountRef": row["default_income_account_ref"],
        "defaultIncomeAccountName": row["default_income_account_name"],
        "defaultIncomeAccountType": row["default_income_account_type"],
        "defaultExpenseAccountRef": row["default_expense_account_ref"],
        "defaultExpenseAccountName": row["default_expense_account_name"],
        "defaultExpenseAccountType": row["default_expense_account_type"],
        "defaultBankAccountRef": row["default_bank_account_ref"],
        "defaultBankAccountName": row["default_bank_account_name"],
        "defaultBankAccountType": row["default_bank_account_type"],
        "defaultCreditCardAccountRef": row["default_credit_card_account_ref"],
        "defaultCreditCardAccountName": row["default_credit_card_account_name"],
        "defaultCreditCardAccountType": row["default_credit_card_account_type"],
        "updatedAt": row["updated_at"],
        "updatedBy": row["updated_by"],
    }


def supplier_order_acceptance_record(row: sqlite3.Row, *, replayed: bool) -> dict[str, object]:
    raw = row["acceptance_json"]
    if not isinstance(raw, str) or not raw:
        raise ValueError("Supplier acceptance is unavailable")
    decoded = json.loads(raw)
    if not isinstance(decoded, dict):
        raise ValueError("Supplier acceptance is invalid")
    allowed_keys = {
        "contractVersion",
        "purchaseOrderID",
        "purchaseOrderNumber",
        "connectorKind",
        "externalOrderID",
        "reference",
        "supplierLocation",
        "confirmedUnitCost",
        "confirmedShippingCost",
        "currencyCode",
        "confirmedByEmail",
        "confirmedAt",
        "priceAvailabilityCheckedAt",
        "idempotencyKey",
    }
    safe = {key: value for key, value in decoded.items() if key in allowed_keys}
    safe["replayed"] = replayed
    return safe


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
        if parsed.path == "/api/readiness":
            if not self.require_admin():
                return
            self.write_json(backend_readiness_snapshot())
            return
        if parsed.path == "/api/supplier-connectors":
            if not self.require_admin():
                return
            self.write_json({"connectors": supplier_connector_records()})
            return
        if parsed.path == "/api/push-devices/current":
            if not self.require_application_session():
                return
            installation_ids = urllib.parse.parse_qs(parsed.query).get("installationID", [])
            installation_id = installation_ids[0] if len(installation_ids) == 1 else ""
            self.current_push_device(installation_id)
            return
        if parsed.path == "/api/qbo/accounting-config":
            context = current_qbo_connection_context()
            if context is None:
                self.write_json({"error": "QuickBooks is not connected"}, status=HTTPStatus.CONFLICT)
                return
            realm_id, environment = context
            with db() as connection:
                row = connection.execute(
                    "SELECT * FROM qbo_accounting_config WHERE realm_id = ? AND environment = ?",
                    (realm_id, environment),
                ).fetchone()
            self.write_json(
                {
                    "realmID": realm_id,
                    "environment": environment,
                    "configuration": qbo_accounting_configuration_record(row) if row is not None else None,
                }
            )
            return
        if parsed.path == "/api/qbo/webhook-events":
            if not self.require_admin():
                return
            realm_id = current_qbo_realm_id()
            if realm_id is None:
                self.write_json({"events": []})
                return
            with db() as connection:
                rows = connection.execute(
                    """
                    SELECT * FROM qbo_webhook_events
                    WHERE realm_id = ? AND acknowledged_at IS NULL
                    ORDER BY occurred_at ASC, event_id ASC LIMIT 500
                    """,
                    (realm_id,),
                ).fetchall()
            self.write_json({"events": [qbo_webhook_event_record(row) for row in rows]})
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
                rows = [
                    row for row in rows
                    if not document_contains_financial_data(row) or (
                        document_is_maintenance_agreement(row) and
                        self.has_maintenance_agreement_document_access()
                    )
                ]
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
        if parsed.path == "/api/qbo/webhooks":
            self.receive_qbo_webhook()
            return
        if parsed.path == "/api/auth/apple/notifications":
            self.receive_apple_account_notification()
            return
        if parsed.path == "/api/public/service-requests":
            self.store_public_service_request()
            return
        if parsed.path == "/api/auth/apple":
            self.exchange_apple_identity()
            return
        if parsed.path == "/api/auth/google":
            self.exchange_google_identity()
            return
        if self.principal() is None:
            self.write_json({"error": "Unauthorized"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        if parsed.path == "/api/auth/logout":
            self.revoke_application_session()
            return
        if parsed.path == "/api/push-devices":
            if not self.require_application_session():
                return
            self.register_push_device()
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
            if not self.require_communication_sender():
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
        if parsed.path == "/api/qbo/accounting-config":
            if not self.require_admin():
                return
            self.store_qbo_accounting_configuration()
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
        if parsed.path == "/api/qbo/webhook-events/acknowledge":
            if not self.require_admin():
                return
            self.acknowledge_qbo_webhook_events()
            return
        if parsed.path == "/api/supplier-connectors/orders":
            if not self.require_admin():
                return
            self.submit_supplier_connector_order()
            return
        self.write_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def do_DELETE(self) -> None:
        parsed = urlparse(self.path)
        if self.principal() is None:
            self.write_json({"error": "Unauthorized"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        if parsed.path.startswith("/api/push-devices/"):
            if not self.require_application_session():
                return
            installation_id = unquote(parsed.path.removeprefix("/api/push-devices/")).strip()
            self.unregister_push_device(installation_id)
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
                deactivate_push_devices(connection, email=email)
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

        authorization = self.headers.get("Authorization", "").strip()
        if authorization.startswith("Bearer "):
            session_token = authorization.removeprefix("Bearer ").strip()
            session_principal = self.application_session_principal(session_token)
            if session_principal is not None:
                self._principal = session_principal
                return self._principal

        identity_token = self.headers.get("X-GunnAire-Google-ID-Token", "").strip()
        if not identity_token:
            return None
        try:
            claims = verify_google_identity_token(identity_token)
        except ValueError:
            return None
        email = normalize_email(claims.get("email") if isinstance(claims.get("email"), str) else None)
        with db() as connection:
            row = connection.execute("SELECT * FROM users WHERE email = ?", (email,)).fetchone()
        if row is None or not bool(row["is_active"]):
            return None
        self._principal = user_record(row)
        return self._principal

    def application_session_principal(self, token: str) -> dict[str, object] | None:
        if not 32 <= len(token) <= 512:
            return None
        now = datetime.now(timezone.utc)
        with db() as connection:
            session = connection.execute(
                "SELECT * FROM auth_sessions WHERE token_hash = ? AND revoked_at IS NULL",
                (app_session_token_hash(token),),
            ).fetchone()
            if session is None:
                return None
            try:
                expiration = datetime.fromisoformat(str(session["expires_at"]).replace("Z", "+00:00"))
            except ValueError:
                return None
            if expiration.tzinfo is None or expiration.astimezone(timezone.utc) <= now:
                connection.execute(
                    "UPDATE auth_sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
                    (now.isoformat(), session["id"]),
                )
                deactivate_push_devices(connection, session_id=str(session["id"]))
                return None
            user = connection.execute(
                "SELECT * FROM users WHERE email = ?",
                (normalize_email(session["email"]),),
            ).fetchone()
            if user is None or not bool(user["is_active"]):
                deactivate_push_devices(connection, session_id=str(session["id"]))
                return None
            connection.execute(
                "UPDATE auth_sessions SET last_used_at = ? WHERE id = ?",
                (now.isoformat(), session["id"]),
            )
        self._application_session_id = str(session["id"])
        return user_record(user)

    def exchange_apple_identity(self) -> None:
        try:
            raw = self.read_limited_body(20 * 1024)
            payload = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            self.write_json({"error": "Invalid Apple authentication request"}, status=HTTPStatus.BAD_REQUEST, require_auth=False)
            return
        identity_token = payload.get("identityToken") if isinstance(payload, dict) else None
        nonce = payload.get("nonce") if isinstance(payload, dict) else None
        if not isinstance(identity_token, str) or not isinstance(nonce, str):
            self.write_json({"error": "Invalid Apple authentication request"}, status=HTTPStatus.BAD_REQUEST, require_auth=False)
            return
        try:
            claims = verify_apple_identity_token(identity_token, nonce)
        except ValueError:
            self.write_json({"error": "Apple authentication failed"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        email = normalize_email(claims.get("email") if isinstance(claims.get("email"), str) else None)
        provider_subject = claims.get("sub") if isinstance(claims.get("sub"), str) else ""
        with db() as connection:
            user = connection.execute("SELECT * FROM users WHERE email = ?", (email,)).fetchone()
        if user is None or not bool(user["is_active"]):
            self.write_json({"error": "Business account access is not approved"}, status=HTTPStatus.FORBIDDEN, require_auth=False)
            return
        if not link_apple_identity(email, provider_subject):
            self.write_json(
                {"error": "Apple identity is already linked to another business account"},
                status=HTTPStatus.FORBIDDEN,
                require_auth=False,
            )
            return
        session_token, expires_at = create_app_session(email, "apple", provider_subject)
        record_audit_event(email, "sign-in", "apple-application-session")
        self.write_json(
            {
                "sessionToken": session_token,
                "expiresAt": expires_at,
                "providerSubject": provider_subject,
                "user": user_record(user),
            },
            require_auth=False,
        )

    def receive_apple_account_notification(self) -> None:
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            self.write_json(
                {"error": "Invalid Apple account notification"},
                status=HTTPStatus.BAD_REQUEST,
                require_auth=False,
            )
            return
        try:
            raw = self.read_limited_body(20 * 1024)
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            self.write_json(
                {"error": "Invalid Apple account notification"},
                status=HTTPStatus.BAD_REQUEST,
                require_auth=False,
            )
            return
        signed_payload = body.get("payload") if isinstance(body, dict) else None
        if (
            not isinstance(body, dict)
            or set(body) != {"payload"}
            or not isinstance(signed_payload, str)
            or not signed_payload
        ):
            self.write_json(
                {"error": "Invalid Apple account notification"},
                status=HTTPStatus.BAD_REQUEST,
                require_auth=False,
            )
            return
        try:
            event = verify_apple_account_notification(signed_payload)
        except ValueError:
            self.write_json(
                {"error": "Apple account notification verification failed"},
                status=HTTPStatus.UNAUTHORIZED,
                require_auth=False,
            )
            return
        try:
            result = process_apple_account_notification(event)
        except sqlite3.Error:
            self.write_json(
                {"error": "Apple account notification processing is unavailable"},
                status=HTTPStatus.SERVICE_UNAVAILABLE,
                require_auth=False,
            )
            return
        self.write_json(result, require_auth=False)

    def exchange_google_identity(self) -> None:
        try:
            raw = self.read_limited_body(20 * 1024)
            payload = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            self.write_json({"error": "Invalid Google authentication request"}, status=HTTPStatus.BAD_REQUEST, require_auth=False)
            return
        identity_token = payload.get("identityToken") if isinstance(payload, dict) else None
        if not isinstance(identity_token, str):
            self.write_json({"error": "Invalid Google authentication request"}, status=HTTPStatus.BAD_REQUEST, require_auth=False)
            return
        try:
            claims = verify_google_identity_token(identity_token)
        except ValueError:
            self.write_json({"error": "Google authentication failed"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        email = normalize_email(claims.get("email") if isinstance(claims.get("email"), str) else None)
        provider_subject = claims.get("sub") if isinstance(claims.get("sub"), str) else ""
        with db() as connection:
            user = connection.execute("SELECT * FROM users WHERE email = ?", (email,)).fetchone()
        if user is None or not bool(user["is_active"]):
            self.write_json({"error": "Business account access is not approved"}, status=HTTPStatus.FORBIDDEN, require_auth=False)
            return
        session_token, expires_at = create_app_session(email, "google", provider_subject)
        record_audit_event(email, "sign-in", "google-application-session")
        self.write_json(
            {
                "sessionToken": session_token,
                "expiresAt": expires_at,
                "providerSubject": provider_subject,
                "user": user_record(user),
            },
            require_auth=False,
        )

    def require_application_session(self) -> bool:
        principal = self.principal()
        session_id = getattr(self, "_application_session_id", None)
        if principal is not None and isinstance(session_id, str) and session_id:
            return True
        self.write_json(
            {"error": "A current GunnAire application session is required"},
            status=HTTPStatus.FORBIDDEN,
            require_auth=False,
        )
        return False

    def register_push_device(self) -> None:
        try:
            raw = self.read_limited_body(16 * 1024)
            payload = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            self.write_json({"error": "Invalid push registration"}, status=HTTPStatus.BAD_REQUEST)
            return
        if not isinstance(payload, dict):
            self.write_json({"error": "Invalid push registration"}, status=HTTPStatus.BAD_REQUEST)
            return
        try:
            installation_id = str(uuid.UUID(str(payload.get("installationID") or "")))
        except ValueError:
            self.write_json({"error": "Invalid installation identifier"}, status=HTTPStatus.BAD_REQUEST)
            return
        raw_token = str(payload.get("deviceToken") or "").strip().lower()
        platform = str(payload.get("platform") or "").strip()
        environment = str(payload.get("environment") or "").strip().lower()
        bundle_id = str(payload.get("bundleID") or "").strip()
        app_version = str(payload.get("appVersion") or "").strip()
        app_build = str(payload.get("appBuild") or "").strip()
        if not re.fullmatch(r"[0-9a-f]{32,512}", raw_token) or len(raw_token) % 2 != 0:
            self.write_json({"error": "Invalid APNs device token"}, status=HTTPStatus.BAD_REQUEST)
            return
        if platform not in {"iOS", "macCatalyst"}:
            self.write_json({"error": "Invalid Apple client platform"}, status=HTTPStatus.BAD_REQUEST)
            return
        if environment not in {"development", "production"}:
            self.write_json({"error": "Invalid APNs environment"}, status=HTTPStatus.BAD_REQUEST)
            return
        if bundle_id != APNS_TOPIC or bundle_id != APPLE_CLIENT_ID:
            self.write_json({"error": "Push registration does not match this app"}, status=HTTPStatus.BAD_REQUEST)
            return
        if (
            len(app_version) > 32
            or len(app_build) > 32
            or (app_version and re.fullmatch(r"[A-Za-z0-9._-]+", app_version) is None)
            or (app_build and re.fullmatch(r"[A-Za-z0-9._-]+", app_build) is None)
        ):
            self.write_json({"error": "Invalid app version metadata"}, status=HTTPStatus.BAD_REQUEST)
            return
        session_id = getattr(self, "_application_session_id", None)
        principal = self.principal() or {}
        email = normalize_email(principal.get("email") if isinstance(principal.get("email"), str) else None)
        if not isinstance(session_id, str) or not session_id or not is_valid_email(email):
            self.write_json({"error": "Application session required"}, status=HTTPStatus.FORBIDDEN)
            return
        try:
            ciphertext = encrypt_push_device_token(raw_token)
        except RuntimeError:
            self.write_json(
                {"error": "Staff notifications are not configured on the server"},
                status=HTTPStatus.SERVICE_UNAVAILABLE,
            )
            return
        fingerprint = hashlib.sha256(raw_token.encode("ascii")).hexdigest()
        now = utc_now()
        with db() as connection:
            existing = connection.execute(
                "SELECT * FROM push_devices WHERE installation_id = ?",
                (installation_id,),
            ).fetchone()
            duplicate_token = connection.execute(
                "SELECT * FROM push_devices WHERE token_fingerprint = ?",
                (fingerprint,),
            ).fetchone()
            if duplicate_token is not None and (existing is None or duplicate_token["id"] != existing["id"]):
                deactivate_push_devices(connection, device_id=str(duplicate_token["id"]))
                connection.execute(
                    """
                    UPDATE push_devices
                    SET token_ciphertext = '', token_fingerprint = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (f"replaced:{duplicate_token['id']}:{fingerprint}", now, duplicate_token["id"]),
                )
            if existing is None:
                device_id = str(uuid.uuid4())
                connection.execute(
                    """
                    INSERT INTO push_devices(
                        id, installation_id, token_ciphertext, token_fingerprint,
                        email, auth_session_id, platform, environment, bundle_id,
                        app_version, app_build, created_at, updated_at, deactivated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                    (
                        device_id, installation_id, ciphertext, fingerprint, email,
                        session_id, platform, environment, bundle_id,
                        app_version or None, app_build or None, now, now,
                    ),
                )
                response_status = HTTPStatus.CREATED
            else:
                device_id = str(existing["id"])
                if existing["email"] != email or existing["auth_session_id"] != session_id:
                    deactivate_push_devices(connection, device_id=device_id)
                connection.execute(
                    """
                    UPDATE push_devices
                    SET token_ciphertext = ?, token_fingerprint = ?, email = ?,
                        auth_session_id = ?, platform = ?, environment = ?, bundle_id = ?,
                        app_version = ?, app_build = ?, updated_at = ?, deactivated_at = NULL
                    WHERE id = ?
                    """,
                    (
                        ciphertext, fingerprint, email, session_id, platform,
                        environment, bundle_id, app_version or None, app_build or None,
                        now, device_id,
                    ),
                )
                response_status = HTTPStatus.OK
            row = connection.execute("SELECT * FROM push_devices WHERE id = ?", (device_id,)).fetchone()
        record_audit_event(email, "register", "staff-push-device", installation_id)
        self.write_json(
            {"registered": True, "device": push_device_record(row)},
            status=response_status,
        )

    def current_push_device(self, installation_id: str) -> None:
        try:
            normalized_id = str(uuid.UUID(installation_id))
        except ValueError:
            self.write_json({"error": "Invalid installation identifier"}, status=HTTPStatus.BAD_REQUEST)
            return
        session_id = getattr(self, "_application_session_id", None)
        principal = self.principal() or {}
        email = normalize_email(principal.get("email") if isinstance(principal.get("email"), str) else None)
        with db() as connection:
            row = connection.execute(
                """
                SELECT * FROM push_devices
                WHERE installation_id = ? AND email = ? AND auth_session_id = ?
                  AND deactivated_at IS NULL
                """,
                (normalized_id, email, session_id),
            ).fetchone()
        self.write_json(
            {"registered": row is not None, "device": push_device_record(row) if row is not None else None}
        )

    def unregister_push_device(self, installation_id: str) -> None:
        try:
            normalized_id = str(uuid.UUID(installation_id))
        except ValueError:
            self.write_json({"error": "Invalid installation identifier"}, status=HTTPStatus.BAD_REQUEST)
            return
        session_id = getattr(self, "_application_session_id", None)
        principal = self.principal() or {}
        email = normalize_email(principal.get("email") if isinstance(principal.get("email"), str) else None)
        with db() as connection:
            deactivated = deactivate_push_devices(
                connection,
                session_id=str(session_id),
                email=email,
                installation_id=normalized_id,
            )
        if deactivated:
            record_audit_event(email, "deactivate", "staff-push-device", normalized_id)
        self.write_json({"installationID": normalized_id, "deactivated": bool(deactivated)})

    def revoke_application_session(self) -> None:
        session_id = getattr(self, "_application_session_id", None)
        principal = self.principal() or {}
        if not isinstance(session_id, str) or not session_id:
            self.write_json({"error": "Application session required"}, status=HTTPStatus.BAD_REQUEST, require_auth=False)
            return
        with db() as connection:
            connection.execute(
                "UPDATE auth_sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
                (utc_now(), session_id),
            )
            deactivate_push_devices(connection, session_id=session_id)
        actor = principal.get("email") if isinstance(principal.get("email"), str) else None
        record_audit_event(actor, "sign-out", "application-session", session_id)
        self.write_json({"revoked": True}, require_auth=False)

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

    def has_maintenance_agreement_document_access(self) -> bool:
        principal = self.principal()
        return principal is not None and principal.get("role") in {
            "Admin", "Accounting", "Dispatcher", "Field Technician",
        }

    def require_dispatch_access(self) -> bool:
        principal = self.principal()
        if principal is not None and principal.get("role") in {"Admin", "Dispatcher"}:
            return True
        self.write_json({"error": "Dispatcher access required"}, status=HTTPStatus.FORBIDDEN, require_auth=False)
        return False

    def require_communication_sender(self) -> bool:
        principal = self.principal()
        if principal is not None and principal.get("role") in {
            "Admin", "Accounting", "Dispatcher", "Field Technician", "Standard",
        }:
            return True
        self.write_json({"error": "Active business account required"}, status=HTTPStatus.FORBIDDEN, require_auth=False)
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

    def read_limited_body(self, maximum_bytes: int) -> bytes:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as error:
            raise ValueError("Invalid content length") from error
        if not 1 <= length <= maximum_bytes:
            raise ValueError("Request body size is invalid")
        data = self.rfile.read(length)
        if len(data) != length:
            raise ValueError("Request body is incomplete")
        return data

    def receive_qbo_webhook(self) -> None:
        if not QBO_WEBHOOK_VERIFIER_TOKEN:
            self.write_json(
                {"error": "QuickBooks webhook receiver is not configured"},
                status=HTTPStatus.SERVICE_UNAVAILABLE,
                require_auth=False,
            )
            return
        try:
            raw_payload = self.read_limited_body(QBO_WEBHOOK_MAX_BYTES)
        except ValueError:
            self.write_json({"error": "Invalid webhook body"}, status=HTTPStatus.BAD_REQUEST, require_auth=False)
            return
        if not verify_qbo_webhook_signature(raw_payload, self.headers.get("intuit-signature")):
            self.write_json({"error": "Invalid webhook signature"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        try:
            events = parse_qbo_cloudevents(raw_payload)
        except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
            self.write_json({"error": "Invalid QuickBooks CloudEvents payload"}, status=HTTPStatus.BAD_REQUEST, require_auth=False)
            return

        expected_realm = current_qbo_realm_id()
        received_at = utc_now()
        stored = 0
        if expected_realm is not None:
            with db() as connection:
                for event in events:
                    if event["realmID"] != expected_realm:
                        continue
                    stored += connection.execute(
                        """
                        INSERT INTO qbo_webhook_events(
                            event_id, realm_id, entity_type, entity_id, operation,
                            occurred_at, received_at, acknowledged_at, acknowledged_by
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL)
                        ON CONFLICT(event_id) DO NOTHING
                        """,
                        (
                            event["eventID"], event["realmID"], event["entityType"],
                            event["entityID"], event["operation"], event["occurredAt"], received_at,
                        ),
                    ).rowcount
        # Always acknowledge a valid signed delivery. Realm-mismatched or duplicate
        # events are intentionally ignored so Intuit does not retry them forever.
        self.write_json({"accepted": True, "stored": stored}, status=HTTPStatus.OK, require_auth=False)

    def acknowledge_qbo_webhook_events(self) -> None:
        try:
            payload = self.read_json()
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
            self.write_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return
        raw_ids = payload.get("eventIDs") if isinstance(payload, dict) else None
        if not isinstance(raw_ids, list) or not 1 <= len(raw_ids) <= 500:
            self.write_json({"error": "Provide 1 to 500 event IDs"}, status=HTTPStatus.BAD_REQUEST)
            return
        event_ids = list(dict.fromkeys(str(value).strip() for value in raw_ids))
        if any(not re.fullmatch(r"[A-Za-z0-9._:-]{1,200}", value) for value in event_ids):
            self.write_json({"error": "Invalid event ID"}, status=HTTPStatus.BAD_REQUEST)
            return
        realm_id = current_qbo_realm_id()
        principal = self.principal() or {}
        actor = principal.get("email") if isinstance(principal.get("email"), str) else None
        acknowledged_at = utc_now()
        updated = 0
        if realm_id is not None:
            placeholders = ",".join("?" for _ in event_ids)
            with db() as connection:
                updated = connection.execute(
                    f"""
                    UPDATE qbo_webhook_events
                    SET acknowledged_at = ?, acknowledged_by = ?
                    WHERE realm_id = ? AND acknowledged_at IS NULL
                      AND event_id IN ({placeholders})
                    """,
                    (acknowledged_at, actor, realm_id, *event_ids),
                ).rowcount
        record_audit_event(actor, "acknowledge", "qbo-webhook-events", str(updated))
        self.write_json({"acknowledged": updated})

    def create_customer_portal_link(self) -> None:
        if not CUSTOMER_PORTAL_ENABLED or portal_url("test") is None:
            self.write_json({"error": "Customer portal is not configured for HTTPS"}, status=HTTPStatus.SERVICE_UNAVAILABLE)
            return
        try:
            payload = self.read_json()
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
            self.write_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return
        if not isinstance(payload, dict):
            self.write_json({"error": "Portal link body must be an object"}, status=HTTPStatus.BAD_REQUEST)
            return
        text_fields = (
            "customerName", "customerEmail", "serviceCallID", "invoiceID",
            "title", "appointmentSummary", "invoiceReference",
        )
        if any(payload.get(key) is not None and not isinstance(payload.get(key), str) for key in text_fields):
            self.write_json({"error": "Portal link text fields are invalid"}, status=HTTPStatus.BAD_REQUEST)
            return

        customer_name = (payload.get("customerName") or "").strip()
        customer_email = normalize_email(payload.get("customerEmail"))
        service_call_id = (payload.get("serviceCallID") or "").strip() or None
        invoice_id = (payload.get("invoiceID") or "").strip() or None
        title = (payload.get("title") or "GunnAire service update").strip()
        appointment_summary = (payload.get("appointmentSummary") or "").strip() or None
        invoice_reference = (payload.get("invoiceReference") or "").strip() or None

        if not customer_name or not is_valid_email(customer_email) or not (service_call_id or invoice_id):
            self.write_json({"error": "Customer, email, and a job or invoice reference are required"}, status=HTTPStatus.BAD_REQUEST)
            return
        try:
            service_call_id = str(uuid.UUID(service_call_id)) if service_call_id else None
            invoice_id = str(uuid.UUID(invoice_id)) if invoice_id else None
        except ValueError:
            self.write_json({"error": "Job and invoice references must be valid UUIDs"}, status=HTTPStatus.BAD_REQUEST)
            return
        if any(len(value) > limit for value, limit in ((customer_name, 300), (customer_email, 254), (title, 200), (appointment_summary or "", 600), (invoice_reference or "", 160), (service_call_id or "", 80), (invoice_id or "", 80))):
            self.write_json({"error": "Portal link fields are too long"}, status=HTTPStatus.BAD_REQUEST)
            return

        raw_balance_due = payload.get("balanceDue")
        balance_due: float | None = None
        if raw_balance_due is not None:
            if isinstance(raw_balance_due, bool) or not isinstance(raw_balance_due, (int, float)):
                self.write_json({"error": "Balance due must be a non-negative amount"}, status=HTTPStatus.BAD_REQUEST)
                return
            balance_due = float(raw_balance_due)
            if not math.isfinite(balance_due) or not 0 <= balance_due <= 999_999_999.99:
                self.write_json({"error": "Balance due must be a non-negative amount"}, status=HTTPStatus.BAD_REQUEST)
                return
            balance_due = round(balance_due, 2)

        requested_days = payload.get("expiresInDays", 14)
        if isinstance(requested_days, bool):
            self.write_json({"error": "Invalid portal expiry"}, status=HTTPStatus.BAD_REQUEST)
            return
        try:
            if isinstance(requested_days, str) and re.fullmatch(r"[0-9]+", requested_days.strip()) is None:
                raise ValueError("non-integral expiry")
            if isinstance(requested_days, float) and not requested_days.is_integer():
                raise ValueError("non-integral expiry")
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
        if (
            not CUSTOMER_PORTAL_ENABLED
            or customer_portal_origin() is None
            or not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", token)
        ):
            self.write_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND, require_auth=False)
            return
        with db() as connection:
            row = connection.execute(
                "SELECT * FROM customer_portal_links WHERE token_hash = ? AND revoked_at IS NULL",
                (portal_token_hash(token),),
            ).fetchone()
            try:
                expires_at = datetime.fromisoformat(str(row["expires_at"]).replace("Z", "+00:00")) if row is not None else None
            except (TypeError, ValueError):
                expires_at = None
            if expires_at is not None and expires_at.tzinfo is None:
                expires_at = None
            if row is not None and expires_at is not None and expires_at > datetime.now(timezone.utc):
                opened_at = utc_now()
                updated = connection.execute(
                    """
                    UPDATE customer_portal_links
                    SET opened_count = opened_count + 1, last_opened_at = ?
                    WHERE id = ? AND revoked_at IS NULL
                    """,
                    (opened_at, row["id"]),
                ).rowcount
            else:
                updated = 0
        if row is None or expires_at is None or updated != 1:
            self.write_json({"error": "This customer link is unavailable"}, status=HTTPStatus.NOT_FOUND, require_auth=False)
            return
        items = [("Appointment", row["appointment_summary"]), ("Invoice", row["invoice_reference"])]
        if row["balance_due"] is not None:
            items.append(("Balance due", f"${float(row['balance_due']):,.2f}"))
        detail_rows = "".join(f"<dt>{html.escape(label)}</dt><dd>{html.escape(str(value))}</dd>" for label, value in items if value)
        content = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>GunnAire service update</title>
<style>body{{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:42rem;margin:clamp(1rem,7vw,3rem) auto;padding:0 1.25rem;color:CanvasText;background:Canvas}}main{{border:1px solid color-mix(in srgb,CanvasText 18%,transparent);border-radius:16px;padding:clamp(1.25rem,5vw,2rem);box-shadow:0 12px 32px color-mix(in srgb,CanvasText 8%,transparent)}}h1{{font-size:clamp(1.55rem,5vw,2.2rem);line-height:1.15}}dt{{font-weight:650;margin-top:1rem}}dd{{margin:.25rem 0}}small{{color:color-mix(in srgb,CanvasText 65%,transparent);line-height:1.45}} </style>
</head>
<body><main aria-labelledby="portal-title"><h1 id="portal-title">{html.escape(str(row['title']))}</h1><p>Hello {html.escape(str(row['customer_name']))},</p><dl>{detail_rows}</dl><p>Please contact GunnAire to request changes or ask a question.</p><small>This secure link expires <time datetime="{html.escape(str(row['expires_at']))}">{html.escape(str(row['expires_at']))}</time>. Do not forward it.</small></main></body>
</html>"""
        data = content.encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=()")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        )
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

    def store_qbo_accounting_configuration(self) -> None:
        context = current_qbo_connection_context()
        if context is None:
            self.write_json({"error": "QuickBooks is not connected"}, status=HTTPStatus.CONFLICT)
            return
        try:
            payload = self.read_json()
            validated = validate_qbo_accounting_configuration(payload)
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
            self.write_json(
                {"error": "Choose valid QuickBooks sales, income, expense, bank, and credit-card mappings"},
                status=HTTPStatus.BAD_REQUEST,
            )
            return

        realm_id, environment = context
        principal = self.principal() or {}
        actor = principal.get("email") if isinstance(principal.get("email"), str) else ""
        updated_at = utc_now()
        with db() as connection:
            connection.execute(
                """
                INSERT INTO qbo_accounting_config(
                    realm_id, environment,
                    default_sales_item_ref, default_sales_item_name, default_sales_item_type,
                    default_income_account_ref, default_income_account_name, default_income_account_type,
                    default_expense_account_ref, default_expense_account_name, default_expense_account_type,
                    default_bank_account_ref, default_bank_account_name, default_bank_account_type,
                    default_credit_card_account_ref, default_credit_card_account_name, default_credit_card_account_type,
                    updated_at, updated_by
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(realm_id, environment) DO UPDATE SET
                    default_sales_item_ref = excluded.default_sales_item_ref,
                    default_sales_item_name = excluded.default_sales_item_name,
                    default_sales_item_type = excluded.default_sales_item_type,
                    default_income_account_ref = excluded.default_income_account_ref,
                    default_income_account_name = excluded.default_income_account_name,
                    default_income_account_type = excluded.default_income_account_type,
                    default_expense_account_ref = excluded.default_expense_account_ref,
                    default_expense_account_name = excluded.default_expense_account_name,
                    default_expense_account_type = excluded.default_expense_account_type,
                    default_bank_account_ref = excluded.default_bank_account_ref,
                    default_bank_account_name = excluded.default_bank_account_name,
                    default_bank_account_type = excluded.default_bank_account_type,
                    default_credit_card_account_ref = excluded.default_credit_card_account_ref,
                    default_credit_card_account_name = excluded.default_credit_card_account_name,
                    default_credit_card_account_type = excluded.default_credit_card_account_type,
                    updated_at = excluded.updated_at,
                    updated_by = excluded.updated_by
                """,
                (
                    realm_id,
                    environment,
                    validated["defaultSalesItemRef"],
                    validated["defaultSalesItemName"],
                    validated["defaultSalesItemType"],
                    validated["defaultIncomeAccountRef"],
                    validated["defaultIncomeAccountName"],
                    validated["defaultIncomeAccountType"],
                    validated["defaultExpenseAccountRef"],
                    validated["defaultExpenseAccountName"],
                    validated["defaultExpenseAccountType"],
                    validated["defaultBankAccountRef"],
                    validated["defaultBankAccountName"],
                    validated["defaultBankAccountType"],
                    validated["defaultCreditCardAccountRef"],
                    validated["defaultCreditCardAccountName"],
                    validated["defaultCreditCardAccountType"],
                    updated_at,
                    normalize_email(actor),
                ),
            )
            row = connection.execute(
                "SELECT * FROM qbo_accounting_config WHERE realm_id = ? AND environment = ?",
                (realm_id, environment),
            ).fetchone()
        record_audit_event(actor, "update", "qbo-accounting-config", realm_id)
        self.write_json(
            {
                "realmID": realm_id,
                "environment": environment,
                "configuration": qbo_accounting_configuration_record(row),
            }
        )

    def submit_supplier_connector_order(self) -> None:
        idempotency_key = self.headers.get("Idempotency-Key", "").strip()
        if SUPPLIER_CONNECTOR_IDEMPOTENCY_PATTERN.fullmatch(idempotency_key) is None:
            self.write_json(
                {"error": "A stable 16-128 character Idempotency-Key is required"},
                status=HTTPStatus.BAD_REQUEST,
            )
            return
        try:
            raw_payload = self.read_limited_body(SUPPLIER_CONNECTOR_MAX_REQUEST_BYTES)
            decoded = json.loads(raw_payload.decode("utf-8"))
            request = validate_supplier_order_request(decoded)
        except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
            self.write_json(
                {"error": "Choose a valid supplier connector, purchase order, part, quantity, and USD cost"},
                status=HTTPStatus.BAD_REQUEST,
            )
            return

        connector_kind = str(request["connectorKind"])
        adapter = SUPPLIER_CONNECTOR_ADAPTERS.get(connector_kind)
        if adapter is None or adapter.kind != connector_kind:
            connector = next(
                record for record in supplier_connector_records() if record["kind"] == connector_kind
            )
            self.write_json(
                {
                    "error": "This supplier connector is not active. Complete provider onboarding and install the approved server adapter before submitting an order.",
                    "connector": connector,
                },
                status=HTTPStatus.CONFLICT,
            )
            return

        principal = self.principal() or {}
        actor = normalize_email(
            principal.get("email") if isinstance(principal.get("email"), str) else None
        )
        request_json = json.dumps(request, separators=(",", ":"), sort_keys=True)
        request_hash = hashlib.sha256(request_json.encode("utf-8")).hexdigest()
        now = utc_now()
        existing: sqlite3.Row | None = None
        try:
            with db() as connection:
                existing = connection.execute(
                    "SELECT * FROM supplier_order_attempts WHERE idempotency_key = ?",
                    (idempotency_key,),
                ).fetchone()
                if existing is not None and existing["request_hash"] != request_hash:
                    self.write_json(
                        {"error": "The Idempotency-Key is already bound to a different purchase order snapshot"},
                        status=HTTPStatus.CONFLICT,
                    )
                    return
                accepted_for_order = connection.execute(
                    """
                    SELECT * FROM supplier_order_attempts
                    WHERE purchase_order_id = ? AND status = 'accepted'
                    """,
                    (request["purchaseOrderID"],),
                ).fetchone()
                if accepted_for_order is not None and accepted_for_order["idempotency_key"] != idempotency_key:
                    self.write_json(
                        {"error": "This purchase order already has an accepted connector order"},
                        status=HTTPStatus.CONFLICT,
                    )
                    return
                if existing is None:
                    connection.execute(
                        """
                        INSERT INTO supplier_order_attempts(
                            idempotency_key, request_hash, purchase_order_id,
                            purchase_order_number, connector_kind, actor_email,
                            request_json, status, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'submitting', ?, ?)
                        """,
                        (
                            idempotency_key,
                            request_hash,
                            request["purchaseOrderID"],
                            request["purchaseOrderNumber"],
                            connector_kind,
                            actor,
                            request_json,
                            now,
                            now,
                        ),
                    )
        except sqlite3.IntegrityError:
            self.write_json(
                {"error": "This purchase order already has an active or accepted connector submission"},
                status=HTTPStatus.CONFLICT,
            )
            return

        if existing is not None and existing["status"] == "accepted":
            try:
                acceptance = supplier_order_acceptance_record(existing, replayed=True)
            except (ValueError, json.JSONDecodeError):
                self.write_json(
                    {"error": "The retained supplier acceptance cannot be reconciled safely"},
                    status=HTTPStatus.CONFLICT,
                )
                return
            self.write_json({"acceptance": acceptance})
            return
        if existing is not None and existing["status"] == "rejected":
            self.write_json(
                {"error": "The supplier definitively rejected this idempotent request; correct the purchase order before creating a new request"},
                status=HTTPStatus.CONFLICT,
            )
            return

        should_recover = existing is not None and existing["status"] == "unknown"
        if existing is not None and existing["status"] == "submitting":
            try:
                last_update = datetime.fromisoformat(str(existing["updated_at"]).replace("Z", "+00:00"))
            except ValueError:
                last_update = datetime.now(timezone.utc)
            if datetime.now(timezone.utc) - last_update.astimezone(timezone.utc) < timedelta(minutes=5):
                self.write_json(
                    {"error": "This supplier order is already being submitted"},
                    status=HTTPStatus.CONFLICT,
                )
                return
            should_recover = True
            with db() as connection:
                connection.execute(
                    "UPDATE supplier_order_attempts SET status = 'unknown', updated_at = ? WHERE idempotency_key = ?",
                    (utc_now(), idempotency_key),
                )

        try:
            if should_recover:
                adapter_response = adapter.recover_order(request, idempotency_key)
                if adapter_response is None:
                    record_audit_event(actor, "recovery-pending", "supplier-order", str(request["purchaseOrderID"]))
                    self.write_json(
                        {
                            "error": "The supplier outcome is still unknown. Check the supplier account or contact the branch before trying another order.",
                            "outcomeUnknown": True,
                        },
                        status=HTTPStatus.CONFLICT,
                    )
                    return
            else:
                adapter_response = adapter.submit_order(request, idempotency_key)
            acceptance = validate_supplier_order_acceptance(
                adapter_response,
                request,
                actor_email=actor if existing is None else str(existing["actor_email"]),
                idempotency_key=idempotency_key,
            )
        except SupplierConnectorFailure as error:
            result_status = "unknown" if error.outcome_unknown else "rejected"
            with db() as connection:
                connection.execute(
                    """
                    UPDATE supplier_order_attempts
                    SET status = ?, error_code = ?, updated_at = ?
                    WHERE idempotency_key = ?
                    """,
                    (result_status, error.code[:80], utc_now(), idempotency_key),
                )
            record_audit_event(
                actor,
                "outcome-unknown" if error.outcome_unknown else "rejected",
                "supplier-order",
                str(request["purchaseOrderID"]),
            )
            self.write_json(
                {
                    "error": error.safe_message,
                    "errorCode": error.code,
                    "outcomeUnknown": error.outcome_unknown,
                },
                status=HTTPStatus.BAD_GATEWAY if error.outcome_unknown else HTTPStatus.UNPROCESSABLE_ENTITY,
            )
            return
        except Exception:
            with db() as connection:
                connection.execute(
                    """
                    UPDATE supplier_order_attempts
                    SET status = 'unknown', error_code = 'adapter-exception', updated_at = ?
                    WHERE idempotency_key = ?
                    """,
                    (utc_now(), idempotency_key),
                )
            record_audit_event(actor, "outcome-unknown", "supplier-order", str(request["purchaseOrderID"]))
            self.write_json(
                {
                    "error": "The supplier response was interrupted. Check the supplier account before trying another order.",
                    "errorCode": "adapter-exception",
                    "outcomeUnknown": True,
                },
                status=HTTPStatus.BAD_GATEWAY,
            )
            return

        acceptance_json = json.dumps(acceptance, separators=(",", ":"), sort_keys=True)
        try:
            with db() as connection:
                connection.execute(
                    """
                    UPDATE supplier_order_attempts
                    SET status = 'accepted', acceptance_json = ?, error_code = NULL, updated_at = ?
                    WHERE idempotency_key = ?
                    """,
                    (acceptance_json, utc_now(), idempotency_key),
                )
        except sqlite3.IntegrityError:
            record_audit_event(actor, "duplicate-attention", "supplier-order", str(request["purchaseOrderID"]))
            self.write_json(
                {"error": "The supplier accepted an order that conflicts with another retained acceptance; stop and reconcile with the supplier"},
                status=HTTPStatus.CONFLICT,
            )
            return
        record_audit_event(actor, "submit", "supplier-order", str(request["purchaseOrderID"]))
        response_acceptance = dict(acceptance)
        response_acceptance["replayed"] = should_recover
        self.write_json(
            {"acceptance": response_acceptance},
            status=HTTPStatus.OK if should_recover else HTTPStatus.CREATED,
        )

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
            ("maintenanceContractID", "maintenance_contract_id"),
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
        maintenance_contract_id = references["maintenance_contract_id"]
        customer_equipment_id = references["customer_equipment_id"]
        if maintenance_contract_id is not None:
            try:
                maintenance_contract_id = str(uuid.UUID(maintenance_contract_id))
            except ValueError:
                self.write_json({"error": "maintenanceContractID must be a UUID"}, status=HTTPStatus.BAD_REQUEST)
                return
        is_maintenance_agreement = bool(
            maintenance_contract_id or kind == "maintenance_agreement"
        )
        is_other_financial_document = bool(invoice_id or estimate_id or kind in {
            "invoice", "estimate", "payment", "receipt", "bill", "financial",
            "credit", "statement", "transaction",
        })
        if is_maintenance_agreement and not self.has_maintenance_agreement_document_access():
            self.write_json(
                {"error": "Service agreement document access is required"},
                status=HTTPStatus.FORBIDDEN,
            )
            return
        if is_other_financial_document and not self.has_billing_document_access():
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
                    maintenance_contract_id, customer_equipment_id, equipment_name, customer_name,
                    stored_path, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    document_id,
                    filename,
                    content_type,
                    kind,
                    service_call_id,
                    invoice_id,
                    estimate_id,
                    maintenance_contract_id,
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
                WHERE invoice_id = ? AND status IN ('pending', 'accepted')
                ORDER BY created_at DESC LIMIT 1
                """,
                (invoice_id,),
            ).fetchone()
            if existing is not None:
                if existing["assigned_to"] != assigned_to:
                    self.write_json(
                        {"error": f"This invoice already has an active collection task assigned to {existing['assigned_to']}"},
                        status=HTTPStatus.CONFLICT,
                    )
                    return
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
        try:
            queue_staff_push_event(
                event_key=f"field-payment-assignment:{assignment_id}",
                recipient_email=assigned_to,
                category="field-payment-assignment",
                route="paymentCollection",
                record_id=invoice_id,
            )
        except (ValueError, sqlite3.Error):
            # Assignment creation is authoritative and must remain available when
            # the optional alert path is unavailable. Readiness surfaces backlog
            # and storage failures without disclosing job/payment details.
            pass
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
            if row["status"] == "completed":
                self.write_json({"error": "This collection assignment is already completed"}, status=HTTPStatus.CONFLICT)
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
            if row["status"] == "completed":
                self.write_json({"error": "Completed collection assignments cannot be cancelled"}, status=HTTPStatus.CONFLICT)
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
        principal = self.principal() or {}
        collected_by = normalize_email(principal.get("email") if isinstance(principal.get("email"), str) else None)
        collector_role = principal.get("role")
        if not collected_by:
            self.write_json({"error": "Authenticated collector identity is required"}, status=HTTPStatus.UNAUTHORIZED)
            return
        assignment_changes: list[tuple[str, str]] = []
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
                assignment_changes = reconcile_field_payment_assignments(
                    connection,
                    invoice_id=invoice_id,
                    actor_email=collected_by,
                    actor_role=collector_role,
                    payment_id=payment_id,
                    occurred_at=collected_at,
                )
                self.write_json(
                    {
                        "id": existing["id"],
                        "paymentID": existing["payment_id"],
                        "createdAt": existing["created_at"],
                        "idempotentReplay": True,
                        "assignmentUpdates": [
                            {"id": assignment_id, "status": status}
                            for assignment_id, status in assignment_changes
                        ],
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
            assignment_changes = reconcile_field_payment_assignments(
                connection,
                invoice_id=invoice_id,
                actor_email=collected_by,
                actor_role=collector_role,
                payment_id=payment_id,
                occurred_at=collected_at,
            )

        record_audit_event(collected_by, "upsert", "payment", payment_id)
        for assignment_id, status in assignment_changes:
            record_audit_event(collected_by, status, "field-payment", assignment_id)

        self.write_json(
            {
                "id": row["id"],
                "paymentID": row["payment_id"],
                "createdAt": row["created_at"],
                "assignmentUpdates": [
                    {"id": assignment_id, "status": status}
                    for assignment_id, status in assignment_changes
                ],
            },
            status=HTTPStatus.CREATED,
        )

    def store_customer_communication(self) -> None:
        try:
            payload = self.read_json()
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
            self.write_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return

        record_id = str(payload.get("id") or "").strip()
        customer_name = str(payload.get("customerName") or "").strip()
        customer_email = normalize_email(payload.get("customerEmail") if isinstance(payload.get("customerEmail"), str) else None)
        subject = str(payload.get("subject") or "").strip()
        channel = str(payload.get("channel") or "email").strip().lower()
        raw_recipient = payload.get("recipient") if isinstance(payload.get("recipient"), str) else None
        if channel == "email":
            recipient = normalize_email(raw_recipient)
        elif channel == "text":
            recipient = normalize_text_recipient(raw_recipient)
        else:
            recipient = (raw_recipient or "").strip()
        direction = str(payload.get("direction") or "outbound").strip().lower()
        delivery_status = str(payload.get("deliveryStatus") or "").strip().lower()
        workflow = str(payload.get("workflow") or "general").strip()
        template_version = str(payload.get("templateVersion") or f"{workflow}-v1").strip()
        provider_status_detail = str(payload.get("providerStatusDetail") or "").replace("\r", " ").replace("\n", " ").strip()
        provider_message_id = str(payload.get("providerMessageID") or "").strip() or None
        attachment_names = payload.get("attachmentFileNames")
        if (
            not isinstance(attachment_names, list)
            or len(attachment_names) > 50
            or not all(isinstance(value, str) and 1 <= len(value.strip()) <= 255 for value in attachment_names)
        ):
            self.write_json({"error": "attachmentFileNames must be a string array"}, status=HTTPStatus.BAD_REQUEST)
            return
        try:
            uuid.UUID(record_id)
        except (ValueError, AttributeError):
            self.write_json({"error": "Invalid communication identifier"}, status=HTTPStatus.BAD_REQUEST)
            return
        if not customer_name or len(customer_name) > 200 or not recipient or not subject or len(subject) > 500:
            self.write_json({"error": "Missing communication identity, customer, recipient, or subject"}, status=HTTPStatus.BAD_REQUEST)
            return
        if channel not in {"email", "text"} or direction != "outbound" or delivery_status not in {"sent", "failed", "suppressed"}:
            self.write_json({"error": "Unsupported communication state"}, status=HTTPStatus.BAD_REQUEST)
            return
        if workflow not in SUPPORTED_COMMUNICATION_WORKFLOWS:
            self.write_json({"error": "Unsupported communication workflow"}, status=HTTPStatus.BAD_REQUEST)
            return
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", template_version):
            self.write_json({"error": "Invalid communication template version"}, status=HTTPStatus.BAD_REQUEST)
            return
        if len(provider_status_detail) > 400 or (provider_message_id is not None and len(provider_message_id) > 200):
            self.write_json({"error": "Communication provider metadata is too long"}, status=HTTPStatus.BAD_REQUEST)
            return

        relationship_values: dict[str, str | None] = {}
        for payload_key, storage_key in (
            ("serviceCallID", "service_call_id"),
            ("invoiceID", "invoice_id"),
            ("estimateID", "estimate_id"),
            ("maintenanceContractID", "maintenance_contract_id"),
        ):
            raw_value = str(payload.get(payload_key) or "").strip()
            if not raw_value:
                relationship_values[storage_key] = None
                continue
            try:
                relationship_values[storage_key] = str(uuid.UUID(raw_value))
            except ValueError:
                self.write_json({"error": f"Invalid {payload_key}"}, status=HTTPStatus.BAD_REQUEST)
                return

        consent_snapshot = payload.get("consentSnapshot")
        if consent_snapshot is not None:
            if (
                not isinstance(consent_snapshot, dict)
                or not isinstance(consent_snapshot.get("allowsTransactionalEmail"), bool)
                or not isinstance(consent_snapshot.get("allowsServiceText"), bool)
                or not isinstance(consent_snapshot.get("allowsMarketing"), bool)
                or consent_snapshot.get("preferredContactMethod") not in {"email", "text", "phone"}
                or (
                    consent_snapshot.get("consentUpdatedAt") is not None
                    and not isinstance(consent_snapshot.get("consentUpdatedAt"), str)
                )
            ):
                self.write_json({"error": "Invalid communication consent snapshot"}, status=HTTPStatus.BAD_REQUEST)
                return
        consent_snapshot_json = json.dumps(consent_snapshot, separators=(",", ":"), sort_keys=True) if consent_snapshot else None

        def normalized_timestamp(value: object, *, fallback: str | None = None) -> str | None:
            raw_value = str(value or "").strip()
            if not raw_value:
                return fallback
            parsed = datetime.fromisoformat(raw_value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                raise ValueError("Timestamp must include a timezone")
            return parsed.astimezone(timezone.utc).isoformat()

        try:
            occurred_at = normalized_timestamp(payload.get("occurredAt"), fallback=utc_now())
            delivered_at = normalized_timestamp(
                payload.get("deliveredAt"),
                fallback=occurred_at if delivery_status == "sent" else None,
            )
        except ValueError:
            self.write_json({"error": "Invalid communication timestamp"}, status=HTTPStatus.BAD_REQUEST)
            return
        if delivery_status != "sent":
            delivered_at = None

        principal = self.principal() or {}
        actor_email = normalize_email(principal.get("email") if isinstance(principal.get("email"), str) else None)
        created_at = utc_now()
        with db() as connection:
            existing = connection.execute(
                "SELECT * FROM customer_communications WHERE id = ?", (record_id,)
            ).fetchone()
            if existing is not None:
                same_operation = (
                    existing["customer_name"] == customer_name
                    and existing["channel"] == channel
                    and existing["direction"] == direction
                    and existing["recipient"] == recipient
                    and existing["subject"] == subject
                    and existing["delivery_status"] == delivery_status
                    and existing["workflow"] == workflow
                    and existing["template_version"] == template_version
                )
                if not same_operation:
                    self.write_json(
                        {"error": "Communication identifier already belongs to a different immutable attempt"},
                        status=HTTPStatus.CONFLICT,
                    )
                    return
                connection.execute(
                    """
                    UPDATE customer_communications
                    SET maintenance_contract_id = COALESCE(maintenance_contract_id, ?),
                        workflow = CASE WHEN workflow = 'general' THEN ? ELSE workflow END,
                        template_version = CASE WHEN template_version = 'general-v1' THEN ? ELSE template_version END,
                        actor_email = COALESCE(actor_email, ?),
                        consent_snapshot_json = COALESCE(consent_snapshot_json, ?),
                        provider_status_detail = COALESCE(provider_status_detail, ?),
                        delivered_at = COALESCE(delivered_at, ?),
                        provider_message_id = COALESCE(provider_message_id, ?)
                    WHERE id = ?
                    """,
                    (
                        relationship_values["maintenance_contract_id"], workflow, template_version,
                        actor_email, consent_snapshot_json, provider_status_detail or None,
                        delivered_at, provider_message_id, record_id,
                    ),
                )
                row = connection.execute("SELECT * FROM customer_communications WHERE id = ?", (record_id,)).fetchone()
                self.write_json(communication_record(row), status=HTTPStatus.OK)
                return
            connection.execute(
                """
                INSERT INTO customer_communications(
                    id, customer_name, customer_email, service_call_id, invoice_id, estimate_id,
                    maintenance_contract_id, channel, direction, recipient, subject, delivery_status,
                    workflow, template_version, actor_email, consent_snapshot_json,
                    provider_status_detail, delivered_at, attachment_file_names_json,
                    provider_message_id, occurred_at, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    record_id, customer_name, customer_email,
                    relationship_values["service_call_id"], relationship_values["invoice_id"],
                    relationship_values["estimate_id"], relationship_values["maintenance_contract_id"],
                    channel, direction, recipient, subject, delivery_status, workflow,
                    template_version, actor_email, consent_snapshot_json, provider_status_detail or None,
                    delivered_at, json.dumps([value.strip() for value in attachment_names]),
                    provider_message_id, occurred_at, created_at,
                ),
            )
            row = connection.execute("SELECT * FROM customer_communications WHERE id = ?", (record_id,)).fetchone()
        record_audit_event(actor_email, "create", "customer-communication", record_id)
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
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def send_cors_headers(self) -> None:
        origin = self.headers.get("Origin", "").strip().rstrip("/")
        if origin and origin in ALLOWED_CORS_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, Idempotency-Key, X-GunnAire-Google-ID-Token")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")

    def log_message(self, format: str, *args: object) -> None:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        message = redact_capability_tokens(format % args)
        print(f"{timestamp} {self.address_string()} {message}")


def main() -> None:
    if AUTH_MODE == "api-token" and not API_TOKEN:
        raise SystemExit("Set GUNNAIRE_BACKEND_API_TOKEN before starting api-token mode.")
    initialize_database()
    STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
    start_push_delivery_worker()
    server = ThreadingHTTPServer((HOST, PORT), GunnAireBackendHandler)
    print(f"GunnAire backend listening on http://{HOST}:{PORT}")
    print(f"Service version: {SERVICE_VERSION}")
    print(f"Database: {DB_PATH}")
    print(f"Storage: {STORAGE_ROOT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
