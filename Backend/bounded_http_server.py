"""Shared connection and I/O bounds for both supported backend entrypoints."""

from __future__ import annotations

import math
import threading
from http.server import ThreadingHTTPServer
from typing import Any


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

