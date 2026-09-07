"""Company/user-bound Google web OAuth and server-only credentials.

This is not a generic Google proxy and never returns provider tokens to a client.
Authorization-code exchange and refresh are claimed in SQLite before network
contact. Uncertain outcomes require explicit reconnect, not blind replay.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import secrets
import sqlite3
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

from cryptography.fernet import Fernet, InvalidToken

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
CALLBACK_PATH = "/api/google/oauth/callback"
FEATURE_SCOPES = {
    "mail": {"https://www.googleapis.com/auth/gmail.modify"},
    "calendar": {"https://www.googleapis.com/auth/calendar.events", "https://www.googleapis.com/auth/calendar.calendarlist.readonly"},
    "drive": {"https://www.googleapis.com/auth/drive.file"},
}
IDENTITY_SCOPES = {"openid", "https://www.googleapis.com/auth/userinfo.email"}
ROLES = {"Admin", "Dispatcher", "Field Technician", "Accounting"}
SCHEMA = """
CREATE TABLE IF NOT EXISTS google_oauth_attempts (
 id TEXT PRIMARY KEY, company_id TEXT NOT NULL, actor_email TEXT NOT NULL,
 session_id TEXT NOT NULL, client_id TEXT NOT NULL, redirect_uri TEXT NOT NULL,
 features_json TEXT NOT NULL, state_hash TEXT NOT NULL UNIQUE, secrets_ciphertext TEXT,
 state TEXT NOT NULL CHECK(state IN ('pending','exchanging','connected','denied','review','cancelled','expired')),
 baseline_grant_id TEXT, grant_id TEXT, created_at TEXT NOT NULL, expires_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS google_pending_authorization ON google_oauth_attempts(company_id,actor_email)
 WHERE state IN ('pending','exchanging');
CREATE TABLE IF NOT EXISTS google_account_bindings (
 company_id TEXT NOT NULL, actor_email TEXT NOT NULL, subject TEXT NOT NULL,
 PRIMARY KEY(company_id,actor_email), UNIQUE(company_id,subject)
);
CREATE TABLE IF NOT EXISTS google_connections (
 company_id TEXT NOT NULL, actor_email TEXT NOT NULL, id TEXT NOT NULL UNIQUE,
 subject TEXT NOT NULL, client_id TEXT NOT NULL, scopes_json TEXT NOT NULL,
 secrets_ciphertext TEXT, state TEXT NOT NULL CHECK(state IN ('active','refreshing','review','disconnected')),
 access_expires_at TEXT NOT NULL, refresh_expires_at TEXT, updated_at TEXT NOT NULL,
 PRIMARY KEY(company_id,actor_email)
);
"""


class ConnectionError(Exception):
    def __init__(self, code, message, status=409):
        super().__init__(message)
        self.code, self.status = code, status


def invalid():
    return ConnectionError("invalid_request", "Review the Google connection request.", 400)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def strict_json(data):
    def unique_object(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("Duplicate JSON field")
            value[key] = item
        return value
    def invalid_constant(value):
        raise ValueError("Nonfinite JSON value")
    return json.loads(data, object_pairs_hook=unique_object, parse_constant=invalid_constant)


def identifier(value):
    try:
        if not isinstance(value, str):
            raise ValueError()
        return str(uuid.UUID(value))
    except ValueError:
        raise invalid() from None


def timestamp(value):
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("Missing timezone")
    return result


def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def token_transport(form):
    """Fixed HTTPS destination, bounded response, no redirects or provider-body errors."""
    request = urllib.request.Request(TOKEN_URL, data=urllib.parse.urlencode(form).encode(), method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
            if response.status != 200:
                raise ValueError("Unconfirmed token response")
            data = response.read(64 * 1024 + 1)
        if len(data) > 64 * 1024:
            raise ValueError("Oversized token response")
        payload = strict_json(data)
        if not isinstance(payload, dict):
            raise ValueError("Invalid token response")
        return payload
    except urllib.error.HTTPError as error:
        error.close()
        raise ConnectionError("provider_unconfirmed", "Google did not confirm the connection. Reconnect from the app.", 502) from None
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        raise ConnectionError("provider_unconfirmed", "Google did not confirm the connection. Reconnect from the app.", 502) from None


def verified_claims(token, audience):
    # Lazy import keeps disabled integrations optional in API-token development.
    from google.auth.transport.requests import Request
    from google.oauth2.id_token import verify_oauth2_token
    try:
        return verify_oauth2_token(token, Request(), audience)
    except Exception:
        raise ConnectionError("identity_unconfirmed", "Google account identity could not be verified.", 403) from None


class GoogleConnections:
    def __init__(self, database, audit, *, client_id, client_secret, redirect_uri, encryption_key,
                 allowed_domain, transport=None, claims=None, now=None):
        self.database, self.audit = database, audit
        self.client_id, self.client_secret, self.redirect_uri = client_id, client_secret, redirect_uri
        self.encryption_key, self.allowed_domain = encryption_key, allowed_domain
        self.transport, self.claims = transport or token_transport, claims or verified_claims
        self.now = now or (lambda: datetime.now(timezone.utc))

    def configured(self):
        try:
            uri = urllib.parse.urlsplit(self.redirect_uri)
            valid = (uri.scheme == "https" and uri.hostname and uri.path == CALLBACK_PATH and
                not uri.username and not uri.password and not uri.query and not uri.fragment and
                uri.port in (None, 443) and not any(c.isspace() for c in self.redirect_uri))
            Fernet(self.encryption_key.encode())
        except (ValueError, AttributeError):
            valid = False
        if not valid or not self.client_id or not self.client_secret or not self.allowed_domain:
            raise ConnectionError("not_configured", "Server Google connection is not configured yet.", 503)

    def seal(self, kind, company, owner, record_id, value):
        self.configured()
        return Fernet(self.encryption_key.encode()).encrypt(canonical({"v": 1, "kind": kind, "company": company,
            "owner": owner, "id": record_id, "value": value}).encode()).decode()

    def open(self, kind, row):
        self.configured()
        try:
            payload = json.loads(Fernet(self.encryption_key.encode()).decrypt(row["secrets_ciphertext"].encode()))
            expected = {"v": 1, "kind": kind, "company": row["company_id"], "owner": row["actor_email"], "id": row["id"]}
            if not isinstance(payload, dict) or set(payload) != set(expected) | {"value"} or any(payload[k] != v for k, v in expected.items()):
                raise ValueError()
            return payload["value"]
        except (InvalidToken, ValueError, TypeError, KeyError, AttributeError):
            raise ConnectionError("storage_unavailable", "Saved Google connection needs a secure storage review.", 503) from None

    def authorize(self, connection, session_id, company, *, fresh=False, owner=None):
        actor = connection.execute("SELECT s.*,u.role,u.is_active FROM auth_sessions s JOIN users u ON u.email=s.email WHERE s.id=?",
            (session_id,)).fetchone()
        try:
            valid = (actor is not None and actor["revoked_at"] is None and actor["is_active"] and actor["role"] in ROLES and
                timestamp(actor["created_at"]) <= self.now() < timestamp(actor["expires_at"]) and
                (not fresh or self.now() - timestamp(actor["created_at"]) <= timedelta(minutes=10)) and
                (owner is None or actor["email"] == owner))
        except (ValueError, TypeError, KeyError):
            valid = False
        if not valid:
            raise ConnectionError("access_required", "Sign in again with the original approved business account.", 403)
        identity = connection.execute("SELECT company_id FROM company_identity WHERE singleton=1").fetchone()
        if identity is None or identity[0] != company:
            raise ConnectionError("company_changed", "Reopen the original company workspace.", 403)
        return actor

    def grant(self, connection, company, owner):
        return connection.execute("SELECT * FROM google_connections WHERE company_id=? AND actor_email=?", (company, owner)).fetchone()

    def public_grant(self, row):
        if row is None:
            return {"state": "disconnected", "id": None, "features": []}
        scopes = set(json.loads(row["scopes_json"]))
        return {"id": row["id"], "state": row["state"], "features": sorted(k for k, v in FEATURE_SCOPES.items() if row["state"] == "active" and v <= scopes),
            "updatedAt": row["updated_at"]}

    def status(self, session_id, company):
        company = identifier(company)
        with self.database() as connection:
            actor = self.authorize(connection, session_id, company)
            return self.public_grant(self.grant(connection, company, actor["email"]))

    def attempt_status(self, session_id, attempt_id):
        with self.database() as connection:
            row = connection.execute("SELECT * FROM google_oauth_attempts WHERE id=?", (identifier(attempt_id),)).fetchone()
            if row is None:
                raise ConnectionError("not_found", "Google connection request not found.", 404)
            self.authorize(connection, session_id, row["company_id"], owner=row["actor_email"])
            state = "expired" if row["state"] in ("pending", "exchanging") and timestamp(row["expires_at"]) <= self.now() else row["state"]
            return {"id": row["id"], "state": state, "grantID": row["grant_id"]}

    def start(self, session_id, payload):
        self.configured()
        if not isinstance(payload, dict) or set(payload) != {"id", "companyID", "features"}:
            raise invalid()
        attempt_id, company = identifier(payload["id"]), identifier(payload["companyID"])
        features = payload["features"]
        if (not isinstance(features, list) or not 1 <= len(features) <= len(FEATURE_SCOPES) or
                any(not isinstance(x, str) or x not in FEATURE_SCOPES for x in features) or len(set(features)) != len(features)):
            raise invalid()
        features = sorted(features)
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor = self.authorize(connection, session_id, company, fresh=True)
            row = connection.execute("SELECT * FROM google_oauth_attempts WHERE id=?", (attempt_id,)).fetchone()
            if row is not None:
                if (row["company_id"] != company or row["actor_email"] != actor["email"] or row["session_id"] != session_id or
                        json.loads(row["features_json"]) != features):
                    raise ConnectionError("request_changed", "Start a new Google connection request.")
                if row["state"] != "pending" or timestamp(row["expires_at"]) <= self.now():
                    raise ConnectionError("request_finished", "This request has finished or expired. Check its status before reconnecting.")
                if row["client_id"] != self.client_id or row["redirect_uri"] != self.redirect_uri:
                    raise ConnectionError("configuration_changed", "Google connection settings changed. Start a new request.")
                secret = self.open("attempt", row)
            else:
                if connection.execute("SELECT COUNT(*) FROM google_oauth_attempts WHERE company_id=? AND actor_email=? AND created_at>?",
                        (company, actor["email"], (self.now() - timedelta(hours=1)).isoformat())).fetchone()[0] >= 30:
                    raise ConnectionError("rate_limited", "Too many Google connection requests. Try again later.", 429)
                connection.execute("UPDATE google_oauth_attempts SET state='expired',secrets_ciphertext=NULL WHERE company_id=? AND actor_email=? AND state IN ('pending','exchanging') AND expires_at<=?",
                    (company, actor["email"], self.now().isoformat()))
                if connection.execute("SELECT 1 FROM google_oauth_attempts WHERE company_id=? AND actor_email=? AND state IN ('pending','exchanging')", (company, actor["email"])).fetchone():
                    raise ConnectionError("request_pending", "Finish or cancel the original Google connection request.")
                secret = {"state": secrets.token_urlsafe(48), "nonce": secrets.token_urlsafe(32), "verifier": secrets.token_urlsafe(64)}
                grant = self.grant(connection, company, actor["email"])
                connection.execute("INSERT INTO google_oauth_attempts VALUES (?,?,?,?,?,?,?,?,?,'pending',?,NULL,?,?)",
                    (attempt_id, company, actor["email"], session_id, self.client_id, self.redirect_uri, canonical(features),
                     hashlib.sha256(secret["state"].encode()).hexdigest(), self.seal("attempt", company, actor["email"], attempt_id, secret),
                     grant["id"] if grant else None, self.now().isoformat(), (self.now() + timedelta(minutes=10)).isoformat()))
                self.audit(actor["email"], "prepare", "google-connection", attempt_id, connection=connection)
        scopes = IDENTITY_SCOPES | set().union(*(FEATURE_SCOPES[x] for x in features))
        query = {"client_id": self.client_id, "redirect_uri": self.redirect_uri, "response_type": "code", "scope": " ".join(sorted(scopes)),
            "access_type": "offline", "prompt": "consent", "include_granted_scopes": "true", "state": secret["state"],
            "nonce": secret["nonce"], "login_hint": actor["email"], "hd": self.allowed_domain,
            "code_challenge_method": "S256", "code_challenge": base64.urlsafe_b64encode(hashlib.sha256(secret["verifier"].encode()).digest()).decode().rstrip("=")}
        return {"id": attempt_id, "state": "pending", "authorizationURL": AUTH_URL + "?" + urllib.parse.urlencode(query)}

    def validate_tokens(self, tokens, *, old=None):
        def token(value):
            if not isinstance(value, str) or not 1 <= len(value) <= 16384 or any(ord(c) <= 32 or ord(c) >= 127 for c in value):
                raise ValueError()
            return value
        try:
            if tokens.get("token_type", "").lower() != "bearer" or type(tokens.get("expires_in")) not in (int, float) or not 60 <= tokens["expires_in"] <= 86400:
                raise ValueError()
            access = token(tokens["access_token"])
            refresh = token(tokens.get("refresh_token", (old or {}).get("refresh_token")))
            raw_scopes = tokens.get("scope")
            if raw_scopes is None and old:
                scopes = old["scopes"]
            elif isinstance(raw_scopes, str) and len(raw_scopes) <= 16384:
                scopes = sorted(set("https://www.googleapis.com/auth/userinfo.email" if x == "email" else x for x in raw_scopes.split()))
            else:
                raise ValueError()
            if not IDENTITY_SCOPES <= set(scopes):
                raise ValueError()
            refresh_expiry = (old or {}).get("refresh_expires_at")
            if "refresh_token_expires_in" in tokens:
                seconds = tokens["refresh_token_expires_in"]
                if type(seconds) not in (int, float) or not 60 <= seconds <= 10 * 365 * 86400:
                    raise ValueError()
                refresh_expiry = (self.now() + timedelta(seconds=seconds)).isoformat()
            return {"access_token": access, "refresh_token": refresh, "scopes": scopes,
                "access_expires_at": (self.now() + timedelta(seconds=tokens["expires_in"])).isoformat(), "refresh_expires_at": refresh_expiry}
        except (KeyError, ValueError, TypeError, AttributeError, OverflowError):
            raise ConnectionError("provider_unconfirmed", "Google returned an incomplete offline connection. Reconnect from the app.", 502) from None

    def callback(self, query):
        self.configured()
        if not isinstance(query, str) or len(query) > 24000:
            raise invalid()
        try:
            values = urllib.parse.parse_qs(query, keep_blank_values=True, max_num_fields=12)
        except ValueError:
            raise invalid() from None
        if any(len(v) != 1 for v in values.values()) or set(values) - {"state", "code", "error", "scope", "authuser", "hd", "prompt", "iss"}:
            raise invalid()
        state = values.get("state", [""])[0]
        if not re.fullmatch(r"[A-Za-z0-9_-]{64}", state) or ("code" in values) == ("error" in values):
            raise invalid()
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("SELECT * FROM google_oauth_attempts WHERE state_hash=?", (hashlib.sha256(state.encode()).hexdigest(),)).fetchone()
            if row is None or row["state"] != "pending" or timestamp(row["expires_at"]) <= self.now():
                raise ConnectionError("request_finished", "This Google connection request is no longer active.")
            actor = self.authorize(connection, row["session_id"], row["company_id"], owner=row["actor_email"])
            if row["client_id"] != self.client_id or row["redirect_uri"] != self.redirect_uri:
                raise ConnectionError("configuration_changed", "Google connection settings changed. Reconnect from the app.")
            secret = self.open("attempt", row)
            if not hmac.compare_digest(secret["state"], state):
                raise invalid()
            if "error" in values:
                connection.execute("UPDATE google_oauth_attempts SET state='denied',secrets_ciphertext=NULL WHERE id=?", (row["id"],))
                return {"id": row["id"], "state": "denied"}
            code = values["code"][0]
            if not 1 <= len(code) <= 16384 or any(ord(c) <= 32 or ord(c) >= 127 for c in code):
                raise invalid()
            connection.execute("UPDATE google_oauth_attempts SET state='exchanging' WHERE id=?", (row["id"],))
        try:
            self.check_attempt(row)
            tokens = self.transport({"grant_type": "authorization_code", "code": code, "client_id": self.client_id,
                "client_secret": self.client_secret, "redirect_uri": self.redirect_uri, "code_verifier": secret["verifier"]})
            credentials = self.validate_tokens(tokens)
            id_token = tokens.get("id_token")
            if not isinstance(id_token, str) or not 100 <= len(id_token) <= 16384:
                raise ConnectionError("identity_unconfirmed", "Google did not confirm the original account.", 403)
            claims = self.claims(id_token, self.client_id)
            if (not isinstance(claims, dict) or claims.get("iss") not in ("accounts.google.com", "https://accounts.google.com") or
                    claims.get("aud") != self.client_id or claims.get("azp", self.client_id) != self.client_id or
                    claims.get("nonce") != secret["nonce"] or not (claims.get("email_verified") is True or claims.get("email_verified") == "true") or
                    str(claims.get("email", "")).lower() != row["actor_email"] or claims.get("hd") != self.allowed_domain or
                    not isinstance(claims.get("sub"), str) or not 1 <= len(claims["sub"]) <= 255 or
                    any(ord(c) < 33 or ord(c) > 126 for c in claims["sub"]) or
                    (actor["provider"] == "google" and claims["sub"] != actor["provider_subject"])):
                raise ConnectionError("account_mismatch", "Choose the original approved business Google account.", 403)
            with self.database() as connection:
                connection.execute("BEGIN IMMEDIATE")
                self.check_attempt(row, connection=connection)
                binding = connection.execute("SELECT subject FROM google_account_bindings WHERE company_id=? AND actor_email=?", (row["company_id"], row["actor_email"])).fetchone()
                if binding is not None and binding[0] != claims["sub"]:
                    raise ConnectionError("account_mismatch", "This business login is bound to a different Google account.", 403)
                other = connection.execute("SELECT actor_email FROM google_account_bindings WHERE company_id=? AND subject=?", (row["company_id"], claims["sub"])).fetchone()
                if other is not None and other[0] != row["actor_email"]:
                    raise ConnectionError("account_mismatch", "This Google account belongs to another business login.", 403)
                connection.execute("INSERT OR IGNORE INTO google_account_bindings VALUES (?,?,?)", (row["company_id"], row["actor_email"], claims["sub"]))
                grant_id = str(uuid.uuid4())
                ciphertext = self.seal("grant", row["company_id"], row["actor_email"], grant_id, credentials)
                connection.execute("INSERT INTO google_connections VALUES (?,?,?,?,?,?,?,'active',?,?,?) ON CONFLICT(company_id,actor_email) DO UPDATE SET id=excluded.id,subject=excluded.subject,client_id=excluded.client_id,scopes_json=excluded.scopes_json,secrets_ciphertext=excluded.secrets_ciphertext,state=excluded.state,access_expires_at=excluded.access_expires_at,refresh_expires_at=excluded.refresh_expires_at,updated_at=excluded.updated_at",
                    (row["company_id"], row["actor_email"], grant_id, claims["sub"], self.client_id, canonical(credentials["scopes"]), ciphertext,
                     credentials["access_expires_at"], credentials["refresh_expires_at"], self.now().isoformat()))
                connection.execute("UPDATE google_oauth_attempts SET state='connected',grant_id=?,secrets_ciphertext=NULL WHERE id=?", (grant_id, row["id"]))
                self.audit(row["actor_email"], "connect", "google-connection", grant_id, connection=connection)
            return {"id": row["id"], "state": "connected"}
        except Exception:
            # The claim survives a crash. Never repeat the code exchange.
            with self.database() as connection:
                connection.execute("UPDATE google_oauth_attempts SET state='review',secrets_ciphertext=NULL WHERE id=? AND state='exchanging'", (row["id"],))
            raise

    def check_attempt(self, row, *, connection=None):
        if connection is None:
            with self.database() as current:
                return self.check_attempt(row, connection=current)
        self.authorize(connection, row["session_id"], row["company_id"], owner=row["actor_email"])
        current = connection.execute("SELECT state FROM google_oauth_attempts WHERE id=?", (row["id"],)).fetchone()
        grant = self.grant(connection, row["company_id"], row["actor_email"])
        if (current is None or current[0] != "exchanging" or timestamp(row["expires_at"]) <= self.now() or
                (grant["id"] if grant else None) != row["baseline_grant_id"]):
            raise ConnectionError("request_changed", "The original Google connection changed. Reconnect from the app.")

    def cancel(self, session_id, attempt_id):
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("SELECT * FROM google_oauth_attempts WHERE id=?", (identifier(attempt_id),)).fetchone()
            if row is None:
                raise ConnectionError("not_found", "Google connection request not found.", 404)
            self.authorize(connection, session_id, row["company_id"], owner=row["actor_email"])
            if row["state"] in ("pending", "exchanging"):
                connection.execute("UPDATE google_oauth_attempts SET state='cancelled',secrets_ciphertext=NULL WHERE id=?", (row["id"],))
                self.audit(row["actor_email"], "cancel", "google-connection", row["id"], connection=connection)
        return self.attempt_status(session_id, attempt_id)

    def disconnect(self, session_id, company, grant_id):
        company, grant_id = identifier(company), identifier(grant_id)
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor = self.authorize(connection, session_id, company, fresh=True)
            row = self.grant(connection, company, actor["email"])
            if row is None or row["id"] != grant_id:
                raise ConnectionError("connection_changed", "Review the current Google connection before disconnecting.")
            if row["state"] != "disconnected":
                connection.execute("UPDATE google_connections SET state='disconnected',secrets_ciphertext=NULL,updated_at=? WHERE id=?", (self.now().isoformat(), grant_id))
                connection.execute("UPDATE google_oauth_attempts SET state='cancelled',secrets_ciphertext=NULL WHERE company_id=? AND actor_email=? AND state IN ('pending','exchanging')", (company, actor["email"]))
                self.audit(actor["email"], "disconnect-server", "google-connection", grant_id, connection=connection)
        # Google revocation invalidates the combined project grant, including
        # existing native clients. Do not perform that materially broader action.
        return self.status(session_id, company)

    def access(self, session_id, company, grant_id, required_scopes):
        """Internal service use only. Every caller must also authorize its domain action."""
        self.configured()
        company, grant_id = identifier(company), identifier(grant_id)
        known = set().union(*FEATURE_SCOPES.values())
        if not isinstance(required_scopes, set) or not required_scopes or not required_scopes <= known:
            raise invalid()
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor = self.authorize(connection, session_id, company)
            row = self.grant(connection, company, actor["email"])
            self.check_grant(row, grant_id, required_scopes)
            secret = self.open("grant", row)
            if secret["scopes"] != json.loads(row["scopes_json"]) or secret["access_expires_at"] != row["access_expires_at"] or secret["refresh_expires_at"] != row["refresh_expires_at"]:
                raise ConnectionError("storage_unavailable", "Saved Google credential metadata needs review.", 503)
            if timestamp(row["access_expires_at"]) > self.now() + timedelta(seconds=60):
                return secret["access_token"]
            connection.execute("UPDATE google_connections SET state='refreshing' WHERE id=?", (grant_id,))
        try:
            with self.database() as connection:
                self.authorize(connection, session_id, company, owner=row["actor_email"])
                self.check_grant(self.grant(connection, company, row["actor_email"]), grant_id, required_scopes, state="refreshing")
            credentials = self.validate_tokens(self.transport({"grant_type": "refresh_token", "refresh_token": secret["refresh_token"],
                "client_id": self.client_id, "client_secret": self.client_secret}), old=secret)
            if not required_scopes <= set(credentials["scopes"]):
                raise ConnectionError("scope_required", "Reconnect Google to approve this feature.", 403)
            ciphertext = self.seal("grant", company, row["actor_email"], grant_id, credentials)
            with self.database() as connection:
                connection.execute("BEGIN IMMEDIATE")
                self.authorize(connection, session_id, company, owner=row["actor_email"])
                self.check_grant(self.grant(connection, company, row["actor_email"]), grant_id, required_scopes, state="refreshing")
                connection.execute("UPDATE google_connections SET state='active',secrets_ciphertext=?,scopes_json=?,access_expires_at=?,refresh_expires_at=?,updated_at=? WHERE id=?",
                    (ciphertext, canonical(credentials["scopes"]), credentials["access_expires_at"], credentials["refresh_expires_at"], self.now().isoformat(), grant_id))
            return credentials["access_token"]
        except Exception:
            with self.database() as connection:
                connection.execute("UPDATE google_connections SET state='review' WHERE id=? AND state='refreshing'", (grant_id,))
            raise

    def check_grant(self, row, grant_id, scopes, *, state="active"):
        if row is None or row["id"] != grant_id or row["state"] != state or row["client_id"] != self.client_id:
            raise ConnectionError("connection_changed", "Reconnect the original Google account before continuing.")
        if not scopes <= set(json.loads(row["scopes_json"])):
            raise ConnectionError("scope_required", "Reconnect Google to approve this feature.", 403)
        if row["refresh_expires_at"] and timestamp(row["refresh_expires_at"]) <= self.now():
            raise ConnectionError("connection_expired", "Google access has expired. Reconnect from the app.")
