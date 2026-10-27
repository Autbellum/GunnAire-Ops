"""Admission spans verified reads and slow/failed responses across both routes."""
import concurrent.futures
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import test_staff_workspace_media as fixtures


class DownloadCapacityTests(unittest.TestCase):
    def setUp(self):
        self.f = fixtures.StaffWorkspaceMediaHTTPTests()
        self.f.setUp()
        self.addCleanup(self.f.tearDown)
        self.f.seed_with_media()
        self.general = f"/api/documents/{self.f.document_id}/download"
        self.staff = self.f.media_path(bytes_path=True) + "?" + urllib.parse.urlencode(
            dict(self.f.scope, attachmentID=self.f.attachment_id))

    def get(self, path, token=None):
        headers = {"Authorization": "Bearer " + token} if token else {}
        request = urllib.request.Request(self.f.base_url + path, headers=headers)
        try:
            response = urllib.request.urlopen(request, timeout=8)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, response.read(), dict(response.headers)

    def test_both_routes_share_capacity_through_slow_socket_response(self):
        entered = threading.Barrier(3)
        release = threading.Event()
        original = backend.GunnAireBackendHandler.write_media_bytes
        def slow_write(handler, *args):
            entered.wait(timeout=5)
            if not release.wait(timeout=5):
                raise TimeoutError("fixture response never released")
            return original(handler, *args)
        with mock.patch.object(backend, "DOCUMENT_DOWNLOAD_SLOTS", threading.BoundedSemaphore(2)), \
             mock.patch.object(backend.GunnAireBackendHandler, "write_media_bytes", slow_write), \
             mock.patch.object(backend.document_storage, "read_document", wraps=backend.document_storage.read_document) as reader, \
             concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
            first = workers.submit(self.get, self.general, self.f.tokens["Admin"])
            second = workers.submit(self.get, self.staff, self.f.tokens["Field Technician"])
            try:
                entered.wait(timeout=5)
                self.assertEqual(reader.call_count, 2)
                for route, role in ((self.general, "Admin"), (self.staff, "Field Technician")):
                    status, body, headers = self.get(route, self.f.tokens[role])
                    self.assertEqual(status, 503)
                    self.assertIn(b"retry", body)
                    self.assertEqual(headers["Cache-Control"], "no-store")
                self.assertEqual(reader.call_count, 2, "Busy requests must not allocate file bytes")
                self.assertEqual(self.get(self.general)[0], 401)
                self.assertIn(self.get(self.staff)[0], (401, 403))
                self.assertEqual(self.f.media()[0], 200)
                self.assertEqual(self.f.request(token=self.f.tokens["Admin"],
                    path=f"/api/documents/{self.f.document_id}/manifest")[0], 200)
            finally:
                release.set()
            for result in (first.result(timeout=5), second.result(timeout=5)):
                status, body, headers = result
                self.assertEqual((status, body), (200, self.f.payload_bytes))
                self.assertEqual(headers["Content-Length"], str(len(body)))
                self.assertEqual(headers["Content-Type"], "application/pdf")
                self.assertEqual(headers["Content-Disposition"], 'attachment; filename="Original.pdf"')
                self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(self.get(self.general, self.f.tokens["Admin"])[0], 200)
        self.assertEqual(self.get(self.staff, self.f.tokens["Field Technician"])[0], 200)

    def test_default_capacity_refuses_second_route_without_reading_bytes(self):
        entered = threading.Event()
        release = threading.Event()
        original = backend.GunnAireBackendHandler.write_media_bytes
        def slow_write(handler, *args):
            entered.set()
            if not release.wait(5):
                raise TimeoutError("fixture response never released")
            return original(handler, *args)
        with mock.patch.object(backend.GunnAireBackendHandler, "write_media_bytes", slow_write), \
             mock.patch.object(backend.document_storage, "read_document", wraps=backend.document_storage.read_document) as reader, \
             concurrent.futures.ThreadPoolExecutor(max_workers=1) as worker:
            first = worker.submit(self.get, self.general, self.f.tokens["Admin"])
            try:
                self.assertTrue(entered.wait(5))
                self.assertEqual(self.get(self.staff, self.f.tokens["Field Technician"])[0], 503)
                self.assertEqual(reader.call_count, 1)
            finally:
                release.set()
            self.assertEqual(first.result(5)[0], 200)
        self.assertEqual(self.get(self.staff, self.f.tokens["Field Technician"])[0], 200)

    def test_read_error_releases_capacity_and_preserves_error(self):
        slots = threading.BoundedSemaphore(1)
        with mock.patch.object(backend, "DOCUMENT_DOWNLOAD_SLOTS", slots):
            for route, role in ((self.general, "Admin"), (self.staff, "Field Technician")):
                with self.subTest(route=route), mock.patch.object(backend.document_storage, "read_document",
                    side_effect=backend.document_storage.DocumentReadError(409, "fixture content changed")):
                    status, body, _ = self.get(route, self.f.tokens[role])
                    self.assertEqual(status, 409)
                    self.assertIn(b"fixture content changed", body)
                    self.assertTrue(slots.acquire(blocking=False))
                    slots.release()
            self.assertEqual(self.get(self.general, self.f.tokens["Admin"])[0], 200)

    def test_response_disconnect_timeout_and_error_release_slots(self):
        handler = object.__new__(backend.GunnAireBackendHandler)
        handler.write_json = mock.Mock()
        for error in (BrokenPipeError(), ConnectionResetError(), TimeoutError(), OSError("fixture")):
            with self.subTest(error=type(error).__name__), \
                 mock.patch.object(backend, "DOCUMENT_DOWNLOAD_SLOTS", threading.BoundedSemaphore(1)):
                with self.assertRaises(type(error)):
                    with handler.document_download_capacity() as admitted:
                        self.assertTrue(admitted)
                        self.assertFalse(backend.DOCUMENT_DOWNLOAD_SLOTS.acquire(blocking=False))
                        raise error
                self.assertTrue(backend.DOCUMENT_DOWNLOAD_SLOTS.acquire(blocking=False))
                backend.DOCUMENT_DOWNLOAD_SLOTS.release()


class RealDownloadSocketTests(unittest.TestCase):
    get = DownloadCapacityTests.get

    def setUp(self):
        import socket
        from Backend import test_workspace_identity as identity
        from Backend.gunnaire_local_ai_backend import BoundedBusinessServer
        self.f = fixtures.StaffWorkspaceMediaHTTPTests()
        # Exercise the real production server timeout mechanism with a shorter
        # fixture-only deadline; production still uses its existing 10 seconds.
        with mock.patch.object(identity, "ThreadingHTTPServer",
            side_effect=lambda address, handler: BoundedBusinessServer(address, handler, socket_timeout=.3)):
            self.f.setUp()
        self.addCleanup(self.f.tearDown)
        original = self.f.install_document
        data = b"%PDF-" + b"x" * (8 * 1024 * 1024 - 5)
        def install(identifier, payload, verified=True):
            attachment = fixtures.content_http.fixtures.row(self.f.records, "attachment")
            fixtures.content_http.fixtures.set_value(attachment, "fileSizeBytes", len(data))
            self.f.payload_bytes = data
            return original(identifier, data, verified)
        with mock.patch.object(self.f, "install_document", side_effect=install):
            self.f.seed_with_media()
        self.general = f"/api/documents/{self.f.document_id}/download"
        self.staff = self.f.media_path(bytes_path=True) + "?" + urllib.parse.urlencode(
            dict(self.f.scope, attachmentID=self.f.attachment_id))

    def exercise_failure(self, abort):
        import socket
        import struct
        original = backend.GunnAireBackendHandler.write_media_bytes
        for route, role in ((self.general, "Admin"), (self.staff, "Field Technician")):
            with self.subTest(route=route, abort=abort):
                finished = threading.Event()
                errors = []
                original_finish = backend.GunnAireBackendHandler.finish
                def finish(handler):
                    try:
                        return original_finish(handler)
                    finally:
                        finished.set()  # Handler exit is after the capacity context's finally.
                def small_send_buffer(handler, *args):
                    handler.connection.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
                    try:
                        return original(handler, *args)
                    except (BrokenPipeError, ConnectionResetError, TimeoutError) as error:
                        errors.append(error)
                        raise
                slots = threading.BoundedSemaphore(1)
                with mock.patch.object(backend, "DOCUMENT_DOWNLOAD_SLOTS", slots), \
                     mock.patch.object(self.f.server, "handle_error"), \
                     mock.patch.object(backend.GunnAireBackendHandler, "finish", finish):
                    with mock.patch.object(backend.GunnAireBackendHandler, "write_media_bytes", small_send_buffer):
                        client = socket.socket()
                        client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                        client.settimeout(3)
                        try:
                            client.connect(self.f.server.server_address)
                            client.sendall((f"GET {route} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer "
                                + self.f.tokens[role] + "\r\nConnection: close\r\n\r\n").encode())
                            headers = b""
                            while not headers.endswith(b"\r\n\r\n"):
                                byte = client.recv(1)
                                self.assertTrue(byte)
                                headers += byte
                            self.assertIn(b"200 OK", headers)
                            if abort:
                                client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                                client.close()  # Real TCP reset while server sends verified bytes.
                            # Otherwise stop receiving, forcing actual sendall backpressure/timeout.
                            self.assertTrue(finished.wait(3), "Socket failure did not leave the handler")
                        finally:
                            client.close()
                    self.assertEqual(len(errors), 1)
                    self.assertIsInstance(errors[0], (BrokenPipeError, ConnectionResetError) if abort else TimeoutError)
                    self.assertTrue(slots.acquire(blocking=False), "Failed response leaked the only slot")
                    slots.release()
                    status, body, headers = self.get(route, self.f.tokens[role])
                    self.assertEqual((status, body), (200, self.f.payload_bytes))
                    self.assertEqual(int(headers["Content-Length"]), len(body))

    def test_real_client_reset_releases_each_route_and_next_download_succeeds(self):
        self.exercise_failure(abort=True)

    def test_real_slow_receiver_timeout_releases_each_route_and_next_download_succeeds(self):
        self.exercise_failure(abort=False)
