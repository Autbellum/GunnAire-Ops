"""No provider calls: exercise the deployed empty APNs poll and health paths."""
import gc
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from Backend import gunnaire_backend as backend


class IdleDatabaseLifetimeTests(unittest.TestCase):
    def test_normal_gc_empty_polls_close_every_handle_and_health_needs_no_database(self):
        self.assertTrue(gc.isenabled(), 'This regression must exercise normal GC')
        opened = closed = 0
        class Tracked(sqlite3.Connection):
            def __init__(self, *args, **kwargs):
                nonlocal opened
                super().__init__(*args, **kwargs)
                opened += 1
            def close(self):
                nonlocal closed
                closed += 1
                return super().close()
        connect = sqlite3.connect
        def tracked_connect(*args, **kwargs):
            return connect(*args, **kwargs, factory=Tracked)
        def forbidden_sender(**kwargs):
            self.fail('An empty queue must never contact APNs')
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(backend, 'DB_PATH', Path(directory) / 'fixture.sqlite3'):
                backend.initialize_database()
                with mock.patch.object(backend.sqlite3, 'connect', tracked_connect), \
                     mock.patch.object(backend, 'apns_configuration_is_present', lambda: True), \
                     mock.patch.object(backend, 'push_token_store', lambda: True):
                    for index in range(250):
                        self.assertEqual(backend.deliver_pending_pushes(sender=forbidden_sender), 0)
                        self.assertEqual(opened, index + 1)
                        self.assertEqual(closed, opened)
                handler = object.__new__(backend.GunnAireBackendHandler)
                handler.path = '/health'
                handler.write_json = mock.Mock()
                with mock.patch.object(backend, 'db', side_effect=AssertionError('health opened database')):
                    handler.do_GET()
                self.assertEqual(handler.write_json.call_args.args[0]['status'], 'ok')
                self.assertEqual(handler.write_json.call_args.kwargs['status'], 200)
