"""Exercise Render's exact Backend working directory and start command."""
from pathlib import Path
import http.client
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest


class DirectEntrypointBoundsTests(unittest.TestCase):
    def test_real_entrypoint_rejects_excess_connections_and_expires_partial_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            with socket.socket() as port_socket:
                port_socket.bind(('127.0.0.1', 0))
                port = port_socket.getsockname()[1]
            env = {'PATH': os.environ['PATH'], 'PYTHONDONTWRITEBYTECODE': '1',
                   'GUNNAIRE_BACKEND_HOST': '127.0.0.1', 'GUNNAIRE_BACKEND_PORT': str(port),
                   'GUNNAIRE_BACKEND_AUTH_MODE': 'api-token',
                   'GUNNAIRE_BACKEND_API_TOKEN': 'fixture-only',
                   'GUNNAIRE_PRIMARY_ADMIN_EMAIL': 'owner@example.invalid',
                   'GUNNAIRE_BACKEND_DATA_DIR': directory, 'GUNNAIRE_BACKUP_AUTOMATION': 'off'}
            with open(Path(directory) / 'server.log', 'w') as log:
                process = subprocess.Popen([sys.executable, 'gunnaire_backend.py'],
                    cwd=Path(__file__).resolve().parent, env=env, stdout=log, stderr=log)
                held = []
                try:
                    deadline = time.monotonic() + 10
                    while True:
                        try:
                            c = http.client.HTTPConnection('127.0.0.1', port, timeout=1)
                            c.request('GET', '/health')
                            with c.getresponse() as r:
                                self.assertEqual(r.status, 200); r.read()
                            c.close(); break
                        except OSError:
                            if process.poll() is not None or time.monotonic() > deadline:
                                self.fail('Direct entrypoint did not become healthy')
                            time.sleep(.02)
                    # Each request leaves headers unfinished, occupying a handler.
                    for _ in range(64):
                        s = socket.create_connection(('127.0.0.1', port), timeout=2)
                        s.sendall(b'GET /health HTTP/1.1\r\n'); held.append(s)
                    time.sleep(.15)
                    with socket.create_connection(('127.0.0.1', port), timeout=2) as excess:
                        excess.sendall(b'GET /health HTTP/1.1\r\nHost: fixture\r\n\r\n')
                        try: response = excess.recv(256)
                        except ConnectionResetError: response = b''
                        self.assertEqual(response, b'', 'Entry point admitted request beyond its handler cap')
                    held[0].settimeout(12)
                    self.assertEqual(held[0].recv(1), b'', 'Incomplete headers did not expire')
                    for s in held: s.close()
                    held.clear()
                    deadline = time.monotonic() + 3
                    while True:
                        c = http.client.HTTPConnection('127.0.0.1', port, timeout=1)
                        try:
                            c.request('GET', '/health')
                            with c.getresponse() as r:
                                self.assertEqual(r.status, 200); r.read()
                            break
                        except (OSError, http.client.HTTPException):
                            if time.monotonic() > deadline: raise
                            time.sleep(.02)
                        finally: c.close()
                finally:
                    for s in held: s.close()
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
