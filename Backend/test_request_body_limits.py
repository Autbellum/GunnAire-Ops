"""Reject oversized JSON before reading/allocating it; preserve upload limits."""
import io
import base64
import tempfile
from pathlib import Path
import http.client
import threading
import json
import unittest
from email.message import Message
from unittest import mock

from Backend import gunnaire_backend as backend


class RequestBodyLimitTests(unittest.TestCase):
    def handler(self, length, body=b"{}"):
        handler = object.__new__(backend.GunnAireBackendHandler)
        handler.headers = Message()
        handler.headers["Content-Length"] = str(length)
        handler.rfile = io.BytesIO(body)
        return handler

    def test_oversized_json_is_rejected_before_reading(self):
        handler = self.handler(2**40)
        handler.rfile = mock.Mock()
        with self.assertRaises(json.JSONDecodeError):
            handler.read_json()
        handler.rfile.read.assert_not_called()

    def test_negative_length_is_not_an_empty_request(self):
        with self.assertRaises(json.JSONDecodeError):
            self.handler(-1).read_json()

    def test_truncated_body_is_rejected_even_if_prefix_is_valid_json(self):
        with self.assertRaises(json.JSONDecodeError):
            self.handler(100, b"{}").read_json()

    def test_invalid_length_uses_existing_json_error_contract(self):
        with self.assertRaises(json.JSONDecodeError):
            self.handler("invalid").read_json()

    def test_non_ascii_decimal_lengths_are_rejected_before_reading(self):
        for length in ("+2", "0_2", "-0", " 2", "2 ", "２"):
            with self.subTest(length=length):
                handler = self.handler(length)
                handler.rfile = mock.Mock()
                with self.assertRaises(json.JSONDecodeError):
                    handler.read_json()
                handler.rfile.read.assert_not_called()

    def test_empty_body_preserves_existing_behavior(self):
        self.assertEqual(self.handler(0).read_json(), {})

    def test_exact_default_limit_is_accepted(self):
        body = b'{"value":"' + b'x' * (1024 * 1024 - 12) + b'"}'
        body += b' ' * (1024 * 1024 - len(body))
        self.assertEqual(len(body), 1024 * 1024)
        self.assertIn("value", self.handler(len(body), body).read_json())

    def test_explicit_document_limit_preserves_large_upload(self):
        body = json.dumps({"dataBase64": "A" * (1024 * 1024)}).encode()
        handler = self.handler(len(body), body)
        self.assertIn("dataBase64", handler.read_json(maximum_bytes=len(body)))

    def test_duplicate_lengths_are_rejected_before_reading(self):
        handler = self.handler(2)
        handler.headers["Content-Length"] = "3"
        handler.rfile = mock.Mock()
        with self.assertRaises(json.JSONDecodeError):
            handler.read_json()
        handler.rfile.read.assert_not_called()

    def test_transfer_encoding_is_not_silently_treated_as_empty_json(self):
        handler = self.handler(0)
        handler.headers["Transfer-Encoding"] = "chunked"
        with self.assertRaises(json.JSONDecodeError):
            handler.read_json()


class RequestBodyHTTPTests(unittest.TestCase):
    def test_oversized_metadata_rejected_without_body_and_health_stays_available(self):
        from Backend.gunnaire_local_ai_backend import BoundedBusinessServer, GunnAireLocalAIBackendHandler
        with mock.patch.multiple(backend, AUTH_MODE="api-token", API_TOKEN="fixture-token"):
            server = BoundedBusinessServer(("127.0.0.1", 0), GunnAireLocalAIBackendHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            client = http.client.HTTPConnection(*server.server_address, timeout=2)
            try:
                # No body is sent: rejection must happen from headers alone,
                # before waiting for the declared data or reaching a DB write.
                client.putrequest("POST", "/api/users")
                client.putheader("Authorization", "Bearer fixture-token")
                client.putheader("Content-Length", str(2**40))
                client.endheaders()
                with client.getresponse() as response:
                    self.assertEqual(response.status, 400)
                    self.assertEqual(json.loads(response.read())["error"], "Invalid JSON")
                client.close()
                client.request("GET", "/health")
                with client.getresponse() as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(json.loads(response.read())["status"], "ok")
            finally:
                client.close()
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)


class DocumentUploadBoundaryTests(unittest.TestCase):
    def test_authenticated_large_upload_boundaries_and_readback(self):
        from Backend.gunnaire_local_ai_backend import BoundedBusinessServer, GunnAireLocalAIBackendHandler
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(backend, AUTH_MODE="api-token", API_TOKEN="fixture-token",
                                     DB_PATH=root / "db.sqlite3", STORAGE_ROOT=root / "storage"):
                backend.initialize_database()
                server = BoundedBusinessServer(("127.0.0.1", 0), GunnAireLocalAIBackendHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                client = http.client.HTTPConnection(*server.server_address, timeout=10)
                headers = {"Authorization": "Bearer fixture-token", "Content-Type": "application/json"}
                try:
                    for size in (1024 * 1024 + 1, backend.MAX_DOCUMENT_BYTES, backend.MAX_DOCUMENT_BYTES + 1):
                        with self.subTest(size=size):
                            data = b"x" * size
                            body = json.dumps({"filename": "boundary.pdf", "contentType": "application/pdf",
                                               "dataBase64": base64.b64encode(data).decode("ascii")}).encode()
                            client.request("POST", "/api/documents", body, headers)
                            with client.getresponse() as response:
                                status = response.status
                                created = json.loads(response.read())
                            if size > backend.MAX_DOCUMENT_BYTES:
                                self.assertEqual(status, 413)
                                continue
                            self.assertEqual(status, 201, created)
                            client.request("GET", f"/api/documents/{created['id']}/download", headers=headers)
                            with client.getresponse() as response:
                                self.assertEqual(response.status, 200)
                                self.assertEqual(response.read(), data)
                    with backend.db() as connection:
                        self.assertEqual(connection.execute("SELECT COUNT(*) FROM documents").fetchone()[0], 2)
                finally:
                    client.close()
                    server.shutdown(); server.server_close(); thread.join(timeout=3)


class DocumentUploadCapacityTests(unittest.TestCase):
    def test_busy_upload_is_rejected_before_reading(self):
        handler = object.__new__(backend.GunnAireBackendHandler)
        handler.write_json = mock.Mock()
        handler._store_document = mock.Mock()
        with mock.patch.object(backend, "DOCUMENT_UPLOAD_SLOTS", threading.BoundedSemaphore(1)):
            self.assertTrue(backend.DOCUMENT_UPLOAD_SLOTS.acquire(blocking=False))
            try:
                handler.store_document()
                handler._store_document.assert_not_called()
                self.assertEqual(handler.write_json.call_args.kwargs["status"], 503)
            finally:
                backend.DOCUMENT_UPLOAD_SLOTS.release()

    def test_busy_real_http_returns_503_without_waiting_for_body(self):
        from Backend.gunnaire_local_ai_backend import BoundedBusinessServer, GunnAireLocalAIBackendHandler
        slots = threading.BoundedSemaphore(1)
        slots.acquire()
        with mock.patch.multiple(backend, AUTH_MODE="api-token", API_TOKEN="fixture-token", DOCUMENT_UPLOAD_SLOTS=slots):
            server = BoundedBusinessServer(("127.0.0.1", 0), GunnAireLocalAIBackendHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            client = http.client.HTTPConnection(*server.server_address, timeout=2)
            try:
                client.putrequest("POST", "/api/documents")
                client.putheader("Authorization", "Bearer fixture-token")
                client.putheader("Content-Length", str(12 * 1024 * 1024))
                client.endheaders()
                with client.getresponse() as response:
                    self.assertEqual(response.status, 503)
                    self.assertIn("retry", json.loads(response.read())["error"])
            finally:
                client.close(); slots.release()
                server.shutdown(); server.server_close(); thread.join(timeout=3)

    def test_slot_is_released_after_success_and_storage_failure(self):
        handler = object.__new__(backend.GunnAireBackendHandler)
        for failure in (None, OSError("fixture disk failure")):
            with self.subTest(failure=failure), mock.patch.object(backend, "DOCUMENT_UPLOAD_SLOTS", threading.BoundedSemaphore(1)):
                handler._store_document = mock.Mock(side_effect=failure)
                if failure:
                    with self.assertRaises(OSError): handler.store_document()
                else:
                    handler.store_document()
                self.assertTrue(backend.DOCUMENT_UPLOAD_SLOTS.acquire(blocking=False))
                backend.DOCUMENT_UPLOAD_SLOTS.release()
