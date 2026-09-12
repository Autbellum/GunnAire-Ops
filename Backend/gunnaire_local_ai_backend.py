#!/usr/bin/env python3
"""Authenticated GunnAire backend entrypoint with local-first AI routes.

The canonical business API remains in ``Backend.gunnaire_backend``. This
subclass adds two bounded routes and delegates every other request unchanged.
Ollama is never exposed to the app or network; only this backend may contact its
loopback endpoint.
"""

from __future__ import annotations

import json
import threading
from http import HTTPStatus
from http.server import ThreadingHTTPServer
from typing import Any, Mapping
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
            _GATEWAY = create_gateway()
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


class GunnAireLocalAIBackendHandler(backend.GunnAireBackendHandler):
    server_version = f"{backend.GunnAireBackendHandler.server_version} LocalAI/1.0"

    def do_GET(self) -> None:
        if urlparse(self.path).path != STATUS_PATH:
            super().do_GET()
            return
        if self.principal() is None:
            self.write_json({"error": "Unauthorized"}, status=HTTPStatus.UNAUTHORIZED, require_auth=False)
            return
        try:
            payload = dict(get_gateway().status())
            payload["serviceVersion"] = backend.SERVICE_VERSION
        except Unavailable as error:
            payload = unavailable_status(error.code)
        self.write_json(payload)

    def do_POST(self) -> None:
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
            payload = json.loads(raw.decode("utf-8"))
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
        try:
            response = get_gateway().assist(payload, actor_role=role)
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
        self.write_json(dict(response))

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
    backend.initialize_database()
    backend.STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
    backend.start_push_delivery_worker()
    server = ThreadingHTTPServer((backend.HOST, backend.PORT), GunnAireLocalAIBackendHandler)
    print(f"GunnAire backend with local-first AI listening on http://{backend.HOST}:{backend.PORT}")
    print(f"Service version: {backend.SERVICE_VERSION}")
    print("AI provider: loopback Ollama; hosted fallback disabled; Stable Diffusion image-only")
    print(f"Database: {backend.DB_PATH}")
    print(f"Storage: {backend.STORAGE_ROOT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
