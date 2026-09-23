#!/usr/bin/env python3
"""Authenticated GunnAire backend entrypoint with local-first AI routes.

The canonical business API remains in ``Backend.gunnaire_backend``. This
subclass adds bounded assistance and optional outbound-worker routes.
Ollama stays on loopback, contacted only by the backend or the configured Mac
worker. Business routes retain their original authorization checks.
"""

from __future__ import annotations

import json
import hmac
import math
import os
import sqlite3
import threading
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import ThreadingHTTPServer
from typing import Any, Callable, Mapping
from urllib.parse import urlparse

from Backend import gunnaire_backend as backend
from Backend.local_ai_gateway import (
    Forbidden,
    GatewayError,
    InvalidRequest,
    LocalAIGateway,
    Unavailable,
    create_gateway,
)
from LocalAI.local_ai import PolicyError

STATUS_PATH = "/api/local-ai/status"
ASSIST_PATH = "/api/local-ai/assist"
MAX_ASSIST_BODY_BYTES = 49_152
WORKER_PATHS = {
    "/api/local-ai/worker/heartbeat": "heartbeat",
    "/api/local-ai/worker/claim": "claim",
    "/api/local-ai/worker/complete": "complete",
}
MAX_WORKER_BODY_BYTES = 65_536

_GATEWAY: LocalAIGateway | Any | None = None
_GATEWAY_FAILURE: str | None = None
_GATEWAY_LOCK = threading.Lock()


def reset_gateway_for_tests() -> None:
    global _GATEWAY, _GATEWAY_FAILURE
    with _GATEWAY_LOCK:
        _GATEWAY = None
        _GATEWAY_FAILURE = None


def get_gateway() -> LocalAIGateway | Any:
    global _GATEWAY, _GATEWAY_FAILURE
    with _GATEWAY_LOCK:
        if _GATEWAY is not None:
            return _GATEWAY
        if _GATEWAY_FAILURE is not None:
            raise Unavailable("local_ai_configuration_error", _GATEWAY_FAILURE)
        try:
            transport = os.environ.get("GUNNAIRE_LOCAL_AI_TRANSPORT", "loopback").strip()
            if transport == "outbound-worker":
                from Backend.local_ai_relay import create_relay
                candidate = create_relay()
                try:
                    require_worker_credential_separation(candidate)
                except Exception:
                    candidate.close()
                    raise
                _GATEWAY = candidate
            elif transport == "loopback":
                _GATEWAY = create_gateway()
            else:
                raise InvalidRequest("invalid_configuration", "Unknown local AI transport")
        except (GatewayError, PolicyError, OSError, ValueError) as exc:
            _GATEWAY_FAILURE = "Local AI configuration is unavailable"
            raise Unavailable("local_ai_configuration_error", _GATEWAY_FAILURE) from exc
        return _GATEWAY


def unavailable_status(code: str = "local_ai_configuration_error") -> dict[str, object]:
    return {
        "enabled": False,
        "available": False,
        "status": "unavailable",
        "code": code,
        "provider": "ollama",
        "local": True,
        "endpointScope": "loopback",
        "hostedFallbackEnabled": False,
        "hostedCreditsUsed": 0,
        "stableDiffusionScope": "image-only",
        "supportedTasks": [],
        "serviceVersion": backend.SERVICE_VERSION,
    }


def company_identity() -> str:
    with backend.db() as connection:
        connection.execute("PRAGMA busy_timeout = 1000")
        row = connection.execute("SELECT company_id FROM company_identity WHERE singleton = 1").fetchone()
    if row is None or not isinstance(row["company_id"], str):
        raise Unavailable("local_ai_company_unavailable", "Business identity is unavailable")
    return row["company_id"]


def is_relay(gateway: Any) -> bool:
    from Backend.local_ai_relay import LocalAIRelay
    return isinstance(gateway, LocalAIRelay)


def require_gateway_company(gateway: Any) -> None:
    if is_relay(gateway) and gateway.settings.company_id != company_identity():
        raise Unavailable("local_ai_company_mismatch", "Local AI worker business configuration does not match")
    if is_relay(gateway):
        require_worker_credential_separation(gateway)


def require_worker_credential_separation(gateway: Any) -> None:
    secret = gateway.settings.worker_secret.decode("ascii")
    if backend.API_TOKEN and hmac.compare_digest(gateway.settings.worker_secret, backend.API_TOKEN.encode("utf-8")):
        raise Unavailable("local_ai_credential_collision", "The Mac worker requires its own separate credential")
    try:
        with backend.db() as connection:
            connection.execute("PRAGMA busy_timeout = 1000")
            existing = connection.execute("SELECT 1 FROM auth_sessions WHERE token_hash = ? LIMIT 1",
                                          (backend.app_session_token_hash(secret),)).fetchone()
    except sqlite3.Error:
        raise Unavailable("local_ai_authority_unavailable", "Business authority could not be verified") from None
    if existing is not None:
        raise Unavailable("local_ai_credential_collision", "The Mac worker requires its own separate credential")


def decode_request(raw: bytes) -> dict[str, Any]:
    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in items:
            if key in value:
                raise ValueError("Duplicate JSON key")
            value[key] = item
        return value

    def constant(_: str) -> None:
        raise ValueError("Non-finite JSON number")

    def number(raw_number: str) -> float:
        result = float(raw_number)
        if not math.isfinite(result):
            raise ValueError("Non-finite JSON number")
        return result

    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs,
                           parse_constant=constant, parse_float=number)
    except RecursionError:
        raise ValueError("JSON nesting limit exceeded") from None
    if not isinstance(value, dict):
        raise ValueError("Expected object")
    return value


def authorization_check(handler: Any, principal: Mapping[str, Any]) -> Callable[[], bool]:
    """Capture identity, then recheck its current authority without cached principals."""
    original_company = company_identity()
    original_mode = backend.AUTH_MODE
    email, role = principal.get("email"), principal.get("role")
    session_id = getattr(handler, "_application_session_id", None)
    authorization = handler.headers.get("Authorization", "")
    google_identity = handler.headers.get("X-GunnAire-Google-ID-Token", "")
    token = authorization.removeprefix("Bearer ").strip() if authorization.startswith("Bearer ") else ""
    token_hash = backend.app_session_token_hash(token) if session_id and token else None

    def allowed() -> bool:
        try:
            if backend.AUTH_MODE != original_mode or company_identity() != original_company:
                return False
            if original_mode == "api-token":
                return (email == backend.PRIMARY_ADMIN_EMAIL and role == "Admin" and bool(backend.API_TOKEN)
                        and hmac.compare_digest(authorization, "Bearer " + backend.API_TOKEN))
            with backend.db() as connection:
                connection.execute("PRAGMA busy_timeout = 1000")
                if session_id:
                    session = connection.execute(
                        "SELECT * FROM auth_sessions WHERE id = ? AND token_hash = ? AND revoked_at IS NULL",
                        (session_id, token_hash),
                    ).fetchone()
                    if session is None or backend.normalize_email(session["email"]) != email:
                        return False
                    expiration = datetime.fromisoformat(str(session["expires_at"]).replace("Z", "+00:00"))
                    if expiration.tzinfo is None or expiration.astimezone(timezone.utc) <= datetime.now(timezone.utc):
                        return False
                elif google_identity:
                    claims = backend.verify_google_identity_token(google_identity)
                    if backend.normalize_email(claims.get("email")) != email:
                        return False
                else:
                    return False
                user = connection.execute("SELECT * FROM users WHERE email = ?", (email,)).fetchone()
            return user is not None and bool(user["is_active"]) and user["role"] == role
        except (ValueError, TypeError, KeyError, sqlite3.Error, GatewayError):
            return False

    return allowed


class BoundedBusinessServer(ThreadingHTTPServer):
    """Bound connection handlers and socket I/O independently of model jobs."""
    daemon_threads = True
    request_queue_size = 32

    def __init__(self, address: Any, handler: Any, *, max_active_requests: int = 64,
                 socket_timeout: float = 10.0) -> None:
        if type(max_active_requests) is not int or not 1 <= max_active_requests <= 64:
            raise ValueError("Invalid request capacity")
        if not math.isfinite(socket_timeout) or not 0 < socket_timeout <= 15:
            raise ValueError("Invalid socket timeout")
        self._request_slots = threading.BoundedSemaphore(max_active_requests)
        self._socket_timeout = socket_timeout
        super().__init__(address, handler)

    def get_request(self) -> Any:
        connection, address = super().get_request()
        connection.settimeout(self._socket_timeout)
        return connection, address

    def process_request(self, request: Any, client_address: Any) -> None:
        if not self._request_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._request_slots.release()
            raise

    def process_request_thread(self, request: Any, client_address: Any) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()


class GunnAireLocalAIBackendHandler(backend.GunnAireBackendHandler):
    server_version = f"{backend.GunnAireBackendHandler.server_version} LocalAI/1.0"

    def do_GET(self) -> None:
        if urlparse(self.path).path in WORKER_PATHS:
            self.write_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND, require_auth=False)
            return
        if urlparse(self.path).path != STATUS_PATH:
            super().do_GET()
            return
        if self.principal() is None:
            self.write_json({"error": "Unauthorized"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        try:
            gateway = get_gateway()
            require_gateway_company(gateway)
            payload = dict(gateway.status())
            payload["serviceVersion"] = backend.SERVICE_VERSION
        except Unavailable as error:
            payload = unavailable_status(error.code)
        self.write_json(payload)

    def do_POST(self) -> None:
        worker_method = WORKER_PATHS.get(urlparse(self.path).path)
        if worker_method is not None:
            self._worker_post(worker_method)
            return
        if urlparse(self.path).path != ASSIST_PATH:
            super().do_POST()
            return
        principal = self.principal()
        if principal is None:
            self.write_json({"error": "Unauthorized"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        media_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if media_type != "application/json":
            self.write_json(
                {"error": "Content-Type must be application/json", "code": "unsupported_media_type"},
                status=HTTPStatus.UNSUPPORTED_MEDIA_TYPE,
                require_auth=False,
            )
            return
        try:
            raw = self.read_limited_body(MAX_ASSIST_BODY_BYTES)
            payload = decode_request(raw)
            del raw
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            self.write_json(
                {"error": "Invalid local AI request body", "code": "invalid_request"},
                status=HTTPStatus.BAD_REQUEST,
                require_auth=False,
            )
            return
        if not isinstance(payload, Mapping):
            self.write_json(
                {"error": "Local AI request body must be an object", "code": "invalid_request"},
                status=HTTPStatus.BAD_REQUEST,
                require_auth=False,
            )
            return
        role = principal.get("role") if isinstance(principal.get("role"), str) else ""
        deadline = time.monotonic() + 90
        try:
            gateway = get_gateway()
            require_gateway_company(gateway)
            authorized = authorization_check(self, principal)
            if not authorized():
                raise Forbidden("business_access_changed", "Sign in again before using local AI")
            if is_relay(gateway):
                session_id = getattr(self, "_application_session_id", None)
                if backend.AUTH_MODE == "api-token" or not isinstance(session_id, str) or not session_id:
                    raise Forbidden("business_session_required", "Sign in with a business session before using the Mac worker")
                response = gateway.assist(payload, actor_role=role, authorize=authorized,
                                          scope_id=session_id, deadline=deadline)
            else:
                # Existing local gateway timeout remains unchanged; the relay's
                # original admission deadline only governs outbound jobs.
                deadline = None
                response = gateway.assist(payload, actor_role=role)
            if not authorized():
                raise Forbidden("business_access_changed", "Business access changed before the draft was ready")
        except Forbidden as error:
            self._write_gateway_error(error, HTTPStatus.FORBIDDEN)
            return
        except InvalidRequest as error:
            self._write_gateway_error(error, HTTPStatus.BAD_REQUEST)
            return
        except Unavailable as error:
            self._write_gateway_error(error, HTTPStatus.SERVICE_UNAVAILABLE)
            return
        except GatewayError as error:
            self._write_gateway_error(error, HTTPStatus.BAD_GATEWAY)
            return

        actor = principal.get("email") if isinstance(principal.get("email"), str) else None
        task = response.get("task") if isinstance(response.get("task"), str) else "unknown"
        request_id = response.get("requestID") if isinstance(response.get("requestID"), str) else None
        backend.record_audit_event(actor, "generate-draft", f"local-ai-{task}", request_id)
        if not authorized():
            self._write_gateway_error(Forbidden("business_access_changed", "Business access changed before the draft was released"),
                                      HTTPStatus.FORBIDDEN)
            return
        if deadline is not None and time.monotonic() >= deadline:
            self._write_gateway_error(Unavailable("local_ai_expired", "The local AI request expired before release"),
                                      HTTPStatus.SERVICE_UNAVAILABLE)
            return
        payload.clear()
        self.write_json(dict(response))

    def _worker_post(self, method: str) -> None:
        """Worker credentials authorize only bounded relay operations, never business APIs."""
        try:
            gateway = get_gateway()
            if not is_relay(gateway):
                self.write_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND, require_auth=False)
                return
            if not gateway.authenticate_worker(self.headers.get("Authorization", "")):
                self.write_json({"error": "Unauthorized"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
                return
            require_gateway_company(gateway)
            if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
                self.write_json({"error": "Content-Type must be application/json"},
                                status=HTTPStatus.UNSUPPORTED_MEDIA_TYPE, require_auth=False)
                return
            try:
                payload = decode_request(self.read_limited_body(MAX_WORKER_BODY_BYTES))
            except (ValueError, UnicodeDecodeError):
                raise InvalidRequest("invalid_request", "Invalid worker request body") from None
            response = getattr(gateway, method)(payload)
            self.write_json(dict(response), require_auth=False)
        except Forbidden as error:
            self._write_gateway_error(error, HTTPStatus.FORBIDDEN)
        except InvalidRequest as error:
            self._write_gateway_error(error, HTTPStatus.BAD_REQUEST)
        except Unavailable as error:
            self._write_gateway_error(error, HTTPStatus.SERVICE_UNAVAILABLE)
        except GatewayError as error:
            self._write_gateway_error(error, HTTPStatus.BAD_GATEWAY)

    def _write_gateway_error(self, error: GatewayError, status: HTTPStatus) -> None:
        self.write_json(
            {
                "error": str(error),
                "code": error.code,
                "provider": "ollama",
                "local": True,
                "hostedFallbackUsed": False,
                "hostedCreditsUsed": 0,
                "stableDiffusionUsed": False,
            },
            status=status,
            require_auth=False,
        )


def main() -> None:
    if backend.AUTH_MODE == "api-token" and not backend.API_TOKEN:
        raise SystemExit("Set GUNNAIRE_BACKEND_API_TOKEN before starting api-token mode.")
    backend.configure_live_logging()
    backend.initialize_database()
    backend.STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
    backend.start_push_delivery_worker()
    backend.start_backup_worker()
    server = BoundedBusinessServer((backend.HOST, backend.PORT), GunnAireLocalAIBackendHandler)
    print(f"GunnAire backend with local-first AI listening on http://{backend.HOST}:{backend.PORT}")
    print(f"Service version: {backend.SERVICE_VERSION}")
    print("AI provider: loopback Ollama; hosted fallback disabled; Stable Diffusion image-only")
    print(f"Database: {backend.DB_PATH}")
    print(f"Storage: {backend.STORAGE_ROOT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
