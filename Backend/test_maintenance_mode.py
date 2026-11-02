"""Synthetic maintenance boundaries; no provider or production data access."""
from contextlib import closing
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from Backend import gunnaire_backend as backend


class MaintenanceModeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.settings = mock.patch.multiple(backend, DB_PATH=root / 'fixture.sqlite3',
            STORAGE_ROOT=root / 'files', PRIMARY_ADMIN_EMAIL='owner@example.invalid', AUTH_MODE='google-id-token')
        self.settings.start()
        self.addCleanup(self.settings.stop)
        backend.initialize_database()
        self.token = backend.create_app_session('owner@example.invalid', 'google', 'synthetic')[0]
        self.mode = mock.patch.dict('os.environ', {'GUNNAIRE_MAINTENANCE_MODE': '1'})
        self.mode.start()
        self.addCleanup(self.mode.stop)

    def snapshot(self):
        with closing(sqlite3.connect(backend.DB_PATH)) as connection, connection:
            return list(connection.iterdump())

    def handler(self, token=None):
        handler = object.__new__(backend.GunnAireBackendHandler)
        handler.headers = {'Authorization': 'Bearer ' + (token or self.token)}
        return handler

    def test_valid_session_read_does_not_touch_last_used(self):
        before = self.snapshot()
        self.assertIsNotNone(self.handler().principal())
        self.assertEqual(before, self.snapshot())

    def test_expired_session_denied_without_revocation(self):
        with closing(sqlite3.connect(backend.DB_PATH)) as connection, connection:
            connection.execute("UPDATE auth_sessions SET expires_at='2000-01-01T00:00:00+00:00'")
        before = self.snapshot()
        self.assertIsNone(self.handler().principal())
        self.assertEqual(before, self.snapshot())

    def test_identity_token_fallback_never_contacts_google(self):
        handler = self.handler('invalid')
        handler.headers['X-GunnAire-Google-ID-Token'] = 'synthetic'
        with mock.patch.object(backend, 'verify_google_identity_token', return_value={'email':'owner@example.invalid'}) as verify:
            self.assertIsNone(handler.principal())
            verify.assert_not_called()

    def test_database_is_read_only_outside_explicit_initialization(self):
        before = self.snapshot()
        with self.assertRaises(sqlite3.OperationalError):
            with backend.db() as connection:
                connection.execute('UPDATE users SET is_active=0')
        self.assertEqual(before, self.snapshot())

    def test_workers_do_not_start(self):
        with mock.patch.object(backend.threading, 'Thread') as thread:
            for start in (backend.start_push_delivery_worker, backend.start_billing_estimate_worker, backend.start_backup_worker):
                start()
            thread.assert_not_called()

    def test_all_mutating_routes_and_unsafe_gets_are_unavailable_before_auth(self):
        cases = [('POST','/api/qbo/webhooks'), ('DELETE','/api/users/owner'),
                 ('GET','/api/google/oauth/callback?code=synthetic'), ('GET','/portal/synthetic'),
                 ('GET','/api/customer/invoices'), ('GET','/api/google/mail/operations/synthetic'),
                 ('POST','/api/qbo/webhook-events/acknowledge'), ('POST','/api/supplier-connectors/orders')]
        before = self.snapshot()
        for method, path in cases:
            with self.subTest(method=method, path=path):
                handler = self.handler()
                handler.path = path
                handler.write_json = mock.Mock()
                handler.principal = mock.Mock(side_effect=AssertionError('auth reached'))
                getattr(handler, 'do_' + method)()
                self.assertEqual(handler.write_json.call_args.kwargs['status'], 503)
                handler.principal.assert_not_called()
        self.assertEqual(before, self.snapshot())

    def test_readiness_has_no_write_probe_and_remains_not_release_ready(self):
        before = self.snapshot()
        with mock.patch.object(backend, 'database_readiness_component', side_effect=AssertionError('write probe')):
            result = backend.backend_readiness_snapshot()
        self.assertEqual(result['writeChecks'], 'not_run')
        self.assertFalse(result['releaseReady'])
        self.assertEqual(before, self.snapshot())

    def test_initialization_preserves_disabled_owner_and_freeze_resumes(self):
        with closing(sqlite3.connect(backend.DB_PATH)) as connection, connection:
            connection.execute("UPDATE users SET is_active=0, role='Standard', updated_at='original'")
        before = self.snapshot()
        backend.initialize_database()
        self.assertEqual(before, self.snapshot())
        self.assertIsNone(self.handler().principal())
        self.assertEqual(before, self.snapshot())
        with self.assertRaises(sqlite3.OperationalError):
            with backend.db() as connection:
                connection.execute('DELETE FROM users')

    def test_readonly_missing_database_is_not_created(self):
        missing = Path(self.directory.name) / 'missing' / 'missing.sqlite3'
        with mock.patch.object(backend, 'DB_PATH', missing):
            with self.assertRaises(sqlite3.OperationalError):
                with backend.db():
                    self.fail('unexpected database')
        self.assertFalse(missing.parent.exists())

    def test_background_calls_leave_tokens_pushes_and_webhooks_unchanged(self):
        with closing(sqlite3.connect(backend.DB_PATH)) as connection, connection:
            session = connection.execute('SELECT id FROM auth_sessions').fetchone()[0]
            connection.execute("INSERT INTO qbo_connections VALUES (1,'synthetic','unchanged-ciphertext','sandbox','client','then','then')")
            connection.executemany("INSERT INTO qbo_webhook_events(event_id,realm_id,entity_type,entity_id,operation,occurred_at,received_at) VALUES (?,'synthetic','Invoice','1','Update','then','then')", [(f'synthetic-{i}',) for i in range(134)])
            connection.execute("INSERT INTO push_devices(id,installation_id,token_ciphertext,token_fingerprint,email,auth_session_id,platform,environment,bundle_id,created_at,updated_at) VALUES ('device','installation','invalid-cipher','fingerprint','owner@example.invalid',?,'iOS','development','synthetic','then','then')", (session,))
            connection.execute("INSERT INTO push_deliveries(id,event_key,device_id,recipient_email,category,route,record_id,status,next_attempt_at,created_at,updated_at) VALUES ('push','event','device','owner@example.invalid','assignment','job','record','pending','2000-01-01T00:00:00+00:00','then','then')")
        before = self.snapshot()
        with mock.patch.object(backend, 'apns_configuration_is_present', side_effect=AssertionError('configuration touched')), mock.patch.object(backend, 'sweep_partial_scheduled_backups', side_effect=AssertionError('sweep touched')):
            self.assertEqual(backend.deliver_pending_pushes(), 0)
            self.assertEqual(backend.run_scheduled_backup_if_due(force=True), {'outcome':'maintenance'})
        self.assertEqual(before, self.snapshot())

    def test_direct_provider_and_job_boundaries_reject_before_arguments_or_callbacks(self):
        import importlib
        from Backend import maintenance
        # Deliberately invalid/unbound arguments: the guard must run even before
        # acquiring a DB, refreshing a token, or invoking a before-send fence.
        boundaries = {
            'gunnaire_backend':['qbo_authorized_bearer','qbo_request','send_apns_request','verify_google_identity_token','apple_public_key','sweep_partial_scheduled_backups','prune_scheduled_backups'],
            'google_connections':['GoogleConnections.callback','GoogleConnections.access','token_transport'],
            'google_mail':['MailContext.request','GoogleMail.claim','GoogleMail.recover_send','GoogleMail.recover_action'],
            'billing_estimate_jobs':['EstimateJobs.claim_one','EstimateJobs.run_one'],
            'billing_provider':['BillingQBOProvider.request'],
            'qbo_document_provider':['DocumentQBOProvider.request'],
            'qbo_change_capture':['ChangeCaptureQBOProvider.request'],
            'time_publication_provider':['TimeQBOProvider.request'],
            'time_worker_provider':['TimeWorkerQBOProvider.read'],
            'billing_pdf_drive_upload':['transport'], 'billing_pdf_drive_readback':['transport'],
            'transactional_email':['send_transactional_email'],
        }
        for module_name, names in boundaries.items():
            module = importlib.import_module('Backend.' + module_name)
            for name in names:
                with self.subTest(module=module_name, boundary=name):
                    value = module
                    for part in name.split('.'):
                        value = getattr(value, part)
                    with self.assertRaises(maintenance.MaintenanceUnavailable):
                        value()

    def test_operational_default_still_updates_session_and_allows_mutations(self):
        with mock.patch.dict('os.environ', {'GUNNAIRE_MAINTENANCE_MODE':'0'}):
            before = self.snapshot()
            self.assertIsNotNone(self.handler().principal())
            self.assertNotEqual(before, self.snapshot())
            with backend.db() as connection:
                connection.execute("UPDATE users SET updated_at='normal-mode'")
            handler = self.handler()
            handler.path = '/api/qbo/webhooks'
            self.assertFalse(handler.maintenance_admission('POST'))

    def test_http_safe_reads_and_denials_use_real_server(self):
        import http.client
        import threading
        from http.server import ThreadingHTTPServer
        server = ThreadingHTTPServer(('127.0.0.1', 0), backend.GunnAireBackendHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        before = self.snapshot()
        try:
            for method, path, token, expected in [
                ('GET','/health',None,200), ('GET','/api/session',self.token,200),
                ('GET','/api/readiness',self.token,200), ('GET','/api/session',None,401),
                ('POST','/api/qbo/webhooks',None,503), ('GET','/portal/unknown',None,503),
                ('GET','/api/google/mail/operations/unknown',self.token,503)]:
                with self.subTest(method=method,path=path):
                    connection = http.client.HTTPConnection(*server.server_address, timeout=5)
                    try:
                        headers = {'Authorization':'Bearer '+token} if token else {}
                        connection.request(method,path,headers=headers)
                        response = connection.getresponse()
                        response.read()
                        self.assertEqual(response.status,expected)
                    finally:
                        connection.close()
        finally:
            server.shutdown(); server.server_close(); thread.join()
        self.assertEqual(before,self.snapshot())

    def test_direct_launch_startup_initializes_then_freezes_without_threads(self):
        import os
        import subprocess
        import sys
        script = """
import sqlite3
from unittest import mock
import gunnaire_backend as backend
class Server:
    def __init__(self, *args):
        pass
    def serve_forever(self):
        with backend.db() as connection:
            assert connection.execute('PRAGMA query_only').fetchone()[0] == 1
            assert connection.execute('SELECT count(*) FROM users').fetchone()[0] == 0
            try:
                connection.execute("INSERT INTO users VALUES ('invalid','Admin',1,'then','then')")
            except sqlite3.OperationalError:
                pass
            else:
                raise AssertionError('database writable after startup')
with mock.patch.object(backend, 'BoundedBusinessServer', Server), mock.patch.object(backend.threading, 'Thread', side_effect=AssertionError('worker started')):
    backend.main()
"""
        root = Path(self.directory.name) / 'direct-startup'
        env = {'PATH':os.environ.get('PATH','/usr/bin:/bin'), 'PYTHONDONTWRITEBYTECODE':'1',
               'GUNNAIRE_MAINTENANCE_MODE':'1','GUNNAIRE_BACKEND_AUTH_MODE':'google-id-token','GUNNAIRE_GOOGLE_CLIENT_ID':'synthetic.apps.googleusercontent.com','GUNNAIRE_BACKEND_DATA_DIR':str(root),
               'GUNNAIRE_BACKEND_DB':str(root/'fixture.sqlite3'),
               'GUNNAIRE_BACKEND_STORAGE':str(root/'files')}
        result = subprocess.run([sys.executable,'-c',script], cwd=Path(backend.__file__).parent,
                                env=env,capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_backup_suppression_never_prunes_files(self):
        from Backend import maintenance
        root = Path(self.directory.name) / 'backups'
        root.mkdir()
        sentinel = root / 'partial-synthetic'
        sentinel.write_bytes(b'original synthetic backup')
        before = sentinel.read_bytes()
        with mock.patch.object(backend,'BACKUP_DIRECTORY',root), mock.patch.object(backend,'BACKUP_AUTOMATION_ENABLED',True):
            self.assertEqual(backend.run_scheduled_backup_if_due(force=True),{'outcome':'maintenance'})
            for operation in (lambda: backend.sweep_partial_scheduled_backups(root,now=backend.datetime.now(backend.timezone.utc)),
                              lambda: backend.prune_scheduled_backups(root,keep=0,protect=set())):
                with self.assertRaises(maintenance.MaintenanceUnavailable):
                    operation()
        self.assertEqual(sentinel.read_bytes(),before)

    def test_alternate_ai_handler_cannot_bypass_maintenance_admission(self):
        from Backend import gunnaire_local_ai_backend as ai
        for method,path in [('POST','/api/ai/chat'),('GET','/api/ai/status')]:
            handler = object.__new__(ai.GunnAireLocalAIBackendHandler)
            handler.path = path
            handler.write_json = mock.Mock()
            with mock.patch.object(ai,'get_gateway',side_effect=AssertionError('gateway reached')):
                getattr(handler,'do_'+method)()
            self.assertEqual(handler.write_json.call_args.kwargs['status'],503)


from Backend.test_billing_publications import BillingFixture


class MaintenanceEstimateTests(BillingFixture, unittest.TestCase):
    def test_real_pending_estimate_is_frozen_then_resumes_normally(self):
        from Backend import billing_estimate_jobs, maintenance
        queue = billing_estimate_jobs.EstimateJobs(backend.db, self.publisher)
        queued = queue.enqueue(self.admin, self.estimate())
        with backend.db() as connection:
            before = list(connection.iterdump())
        with mock.patch.dict('os.environ', {'GUNNAIRE_MAINTENANCE_MODE':'1'}):
            for operation in (queue.claim_one, queue.run_one):
                with self.assertRaises(maintenance.MaintenanceUnavailable):
                    operation()
            with backend.db() as connection:
                self.assertEqual(before,list(connection.iterdump()))
            self.assertEqual(self.writes,[])
        self.assertTrue(queue.run_one())
        self.assertEqual(len(self.writes),1)
        self.assertEqual(queue.status(self.admin,queued['publication']['id'])['background']['state'],'confirmed')


class MaintenanceGoogleTests(unittest.TestCase):
    def test_real_authorization_and_refresh_keep_grants_and_attempts_frozen(self):
        from datetime import timedelta
        from Backend import maintenance, google_connections
        from Backend import test_google_connections
        fixture = test_google_connections.GoogleConnectionTests()
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        fixture.start()
        with backend.db() as connection:
            before = list(connection.iterdump())
        with mock.patch.dict('os.environ', {'GUNNAIRE_MAINTENANCE_MODE':'1'}):
            with self.assertRaises(maintenance.MaintenanceUnavailable):
                fixture.service.callback(fixture.callback_query())
            with backend.db() as connection:
                self.assertEqual(before,list(connection.iterdump()))
            self.assertEqual(fixture.calls,[])
        fixture.service.callback(fixture.callback_query())
        grant = fixture.service.status(fixture.admin,fixture.company)['id']
        fixture.now += timedelta(hours=1)
        with backend.db() as connection:
            before = list(connection.iterdump())
        count = len(fixture.calls)
        with mock.patch.dict('os.environ', {'GUNNAIRE_MAINTENANCE_MODE':'1'}):
            with self.assertRaises(maintenance.MaintenanceUnavailable):
                fixture.service.access(fixture.admin,fixture.company,grant,google_connections.FEATURE_SCOPES['mail'])
            with backend.db() as connection:
                self.assertEqual(before,list(connection.iterdump()))
            self.assertEqual(len(fixture.calls),count)
        fixture.service.access(fixture.admin,fixture.company,grant,google_connections.FEATURE_SCOPES['mail'])
        self.assertEqual(len(fixture.calls),count+1)
