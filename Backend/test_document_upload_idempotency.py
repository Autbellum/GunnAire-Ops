import hashlib
import http.client
import json
import socket
import sqlite3
import subprocess
import sys
import unittest
import uuid
from pathlib import Path
from unittest import mock
from Backend import gunnaire_backend as backend
from Backend import test_document_content_proof as proof_tests

class DocumentUploadIdempotencyTests(unittest.TestCase):
    setUp = proof_tests.DocumentContentProofHTTPTests.setUp
    upload = proof_tests.DocumentContentProofHTTPTests.upload
    def test_lost_created_response_retries_to_one_document(self):
        operation = str(uuid.uuid4())
        original = backend.GunnAireBackendHandler.write_json
        dropped = []
        def write(handler, payload, status=200):
            if handler.path == "/api/documents" and int(status) == 201 and not dropped:
                dropped.append(payload["id"])
                handler.close_connection = True
                handler.connection.shutdown(socket.SHUT_RDWR)
                handler.connection.close()
                return
            return original(handler, payload, status=status)
        with mock.patch.object(backend.GunnAireBackendHandler, "write_json", write):
            with self.assertRaises((OSError, http.client.HTTPException)):
                self.upload(operationID=operation)
        status, recovered = self.upload(operationID=operation)
        self.assertEqual(status, 201)
        self.assertEqual(recovered["id"], dropped[0])
        self.assertEqual(recovered["fileSHA256"], hashlib.sha256(b"original-file").hexdigest())
        with backend.db() as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM documents").fetchone()[0],1)

    def test_same_operation_different_bytes_or_metadata_conflicts(self):
        operation=str(uuid.uuid4())
        first=self.upload(operationID=operation)[1]
        for changes in [dict(payload=b"different"),dict(filename="changed.pdf"),dict(customerName="changed")]:
            self.assertEqual(self.upload(operationID=operation,**changes)[0],409)
        self.assertEqual(self.upload(operationID=operation)[1]["id"],first["id"])
        with backend.db() as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM documents").fetchone()[0],1)

    def test_invalid_operation_id_never_writes(self):
        for value in ["", "not-a-uuid", 42, {}, None]:
            self.assertEqual(self.upload(operationID=value)[0],400)
        with backend.db() as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM documents").fetchone()[0],0)

    def test_recovery_is_versioned_read_only_and_actor_scoped(self):
        operation=str(uuid.uuid4())
        path='/api/document-uploads/'+operation
        status, absent=self.f.request(token=self.f.tokens['Admin'],path=path)
        self.assertEqual(status,200)
        self.assertEqual(absent,{'schema':'document-upload-recovery-v1','operationID':operation,'document':None})
        first=self.upload(operationID=operation)[1]
        status,recovered=self.f.request(token=self.f.tokens['Admin'],path=path)
        self.assertEqual(status,200)
        self.assertEqual(recovered['document']['id'],first['id'])
        self.assertEqual(self.f.request(token=self.f.tokens['Field Technician'],path=path)[0],409)
        with backend.db() as c:
            self.assertEqual(c.execute('SELECT COUNT(*) FROM documents').fetchone()[0],1)
            with self.assertRaises(sqlite3.IntegrityError):
                c.execute("UPDATE documents SET upload_operation_id=?",(str(uuid.uuid4()),))

    def test_recovery_rejects_changed_bytes_and_revoked_actor(self):
        operation=str(uuid.uuid4())
        self.upload(operationID=operation)
        with backend.db() as c:
            path=c.execute('SELECT stored_path FROM documents').fetchone()[0]
        from pathlib import Path
        Path(path).write_bytes(b'modified-file')
        self.assertEqual(self.f.request(token=self.f.tokens['Admin'],path='/api/document-uploads/'+operation)[0],409)
        with backend.db() as c:
            c.execute("UPDATE users SET is_active=0 WHERE role='Admin'")
        self.assertIn(self.f.request(token=self.f.tokens['Admin'],path='/api/document-uploads/'+operation)[0],(401,403))

    def test_supported_sequential_load_acknowledges_every_operation_once(self):
        ids=[]
        for _ in range(10):
            operation=str(uuid.uuid4())
            status,created=self.upload(payload=b'x'*(1024*1024),operationID=operation)
            self.assertEqual(status,201)
            self.assertEqual(self.upload(payload=b'x'*(1024*1024),operationID=operation)[1],created)
            ids.append(created['id'])
        self.assertEqual(len(set(ids)),10)
        with backend.db() as c:
            self.assertEqual(c.execute('SELECT COUNT(*) FROM documents').fetchone()[0],10)

    def test_insert_race_removes_only_owned_losing_file(self):
        operation=str(uuid.uuid4())
        first=self.upload(operationID=operation)[1]
        original=backend.GunnAireBackendHandler._replay_document_upload
        calls=[]
        def miss_then_recover(handler,*args):
            calls.append(1)
            return False if len(calls)==1 else original(handler,*args)
        with mock.patch.object(backend.GunnAireBackendHandler,'_replay_document_upload',miss_then_recover):
            status,recovered=self.upload(operationID=operation)
        self.assertEqual((status,recovered['id']),(201,first['id']))
        files=[p for p in backend.STORAGE_ROOT.rglob('*') if p.is_file()]
        self.assertEqual(len(files),1)
        self.assertEqual(files[0].read_bytes(),b'original-file')

    def test_normalized_filename_recovery_keeps_exact_original_content(self):
        for raw,canonical in [(' José.pdf ','Jos_.pdf'),('receipt(1).pdf','receipt_1_.pdf'),('\x1creport.pdf\x85','report.pdf')]:
            operation=str(uuid.uuid4())
            status,created=self.upload(operationID=operation,filename=raw,equipmentName='  ')
            self.assertEqual(status,201)
            self.assertEqual(created['filename'],canonical)
            status,recovered=self.f.request(token=self.f.tokens['Admin'],path='/api/document-uploads/'+operation)
            self.assertEqual(status,200)
            self.assertEqual(recovered['document']['filename'],canonical)
            self.assertIsNone(recovered['document']['equipmentName'])
            self.assertEqual(recovered['document']['fileSHA256'],hashlib.sha256(b'original-file').hexdigest())

    def test_restart_reimport_retains_original_but_new_intent_is_distinct(self):
        operation = str(uuid.uuid4())
        first = self.upload(operationID=operation)[1]
        with backend.db() as connection:
            before = dict(connection.execute('SELECT * FROM documents').fetchone())
        backend.initialize_database()
        backend.initialize_database()
        self.assertEqual(self.upload(operationID=operation)[1], first)
        status, recovered = self.f.request(token=self.f.tokens['Admin'], path='/api/document-uploads/' + operation)
        self.assertEqual((status, recovered['document']['id']), (200, first['id']))
        self.assertNotEqual(self.upload(operationID=str(uuid.uuid4()))[1]['id'], first['id'])
        with backend.db() as connection:
            self.assertEqual(dict(connection.execute('SELECT * FROM documents WHERE id=?', (first['id'],)).fetchone()), before)
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM documents').fetchone()[0], 2)

    def test_legacy_uploads_remain_distinct_without_invented_operation(self):
        first, second = self.upload()[1], self.upload()[1]
        self.assertNotEqual(first['id'], second['id'])
        backend.initialize_database()
        with backend.db() as connection:
            rows = connection.execute('SELECT upload_operation_id,upload_actor_email,upload_request_sha256 FROM documents').fetchall()
            self.assertEqual([tuple(row) for row in rows], [(None, None, None), (None, None, None)])

    def test_recovery_auth_and_exact_path(self):
        path = '/api/document-uploads/' + str(uuid.uuid4())
        self.assertIn(self.f.request(token=None, path=path)[0], (401, 403))
        for suffix in ('?x=1', '/extra', '%2Fextra'):
            self.assertEqual(self.f.request(token=self.f.tokens['Admin'], path=path + suffix)[0], 400)
        self.assertEqual(self.f.request(token=self.f.tokens['Admin'], path='/api/document-uploads/not-a-uuid')[0], 400)

    def test_revocation_during_verified_recovery_returns_no_document(self):
        operation = str(uuid.uuid4())
        self.upload(operationID=operation)
        original = backend.document_storage.read_document
        def revoke(*args, **kwargs):
            result = original(*args, **kwargs)
            with backend.db() as connection:
                connection.execute("UPDATE users SET is_active=0 WHERE role='Admin'")
            return result
        with mock.patch.object(backend.document_storage, 'read_document', revoke):
            status, body = self.f.request(token=self.f.tokens['Admin'], path='/api/document-uploads/' + operation)
        self.assertEqual(status, 403)
        self.assertNotIn('document', body)
        self.assertTrue(backend.DOCUMENT_DOWNLOAD_SLOTS.acquire(blocking=False))
        backend.DOCUMENT_DOWNLOAD_SLOTS.release()

    def test_recovery_capacity_does_not_read_bytes_and_releases_on_corruption(self):
        operation = str(uuid.uuid4())
        self.upload(operationID=operation)
        path = '/api/document-uploads/' + operation
        self.assertTrue(backend.DOCUMENT_DOWNLOAD_SLOTS.acquire(blocking=False))
        try:
            with mock.patch.object(backend.document_storage, 'read_document') as reader:
                self.assertEqual(self.f.request(token=self.f.tokens['Admin'], path=path)[0], 503)
                reader.assert_not_called()
        finally:
            backend.DOCUMENT_DOWNLOAD_SLOTS.release()
        with backend.db() as connection:
            stored = connection.execute('SELECT stored_path FROM documents').fetchone()[0]
        Path(stored).write_bytes(b'modified-file')
        self.assertEqual(self.f.request(token=self.f.tokens['Admin'], path=path)[0], 409)
        self.assertTrue(backend.DOCUMENT_DOWNLOAD_SLOTS.acquire(blocking=False))
        backend.DOCUMENT_DOWNLOAD_SLOTS.release()
        self.assertEqual(self.upload(operationID=operation)[0], 409)

    def test_other_actor_cannot_replay_or_financial_role_bypass(self):
        operation = str(uuid.uuid4())
        first = self.upload(operationID=operation, kind='receipt')[1]
        with backend.db() as connection:
                connection.execute("UPDATE users SET role='Dispatcher' WHERE role='Admin'")
        status, body = self.f.request(token=self.f.tokens['Admin'], path='/api/document-uploads/' + operation)
        self.assertEqual(status, 403)
        self.assertNotIn('document', body)
        self.assertEqual(self.upload(operationID=operation, kind='receipt')[0], 403)
        with backend.db() as connection:
            self.assertEqual(connection.execute('SELECT id FROM documents').fetchone()[0], first['id'])

    def test_same_operation_other_actor_post_conflicts(self):
        import base64
        operation = str(uuid.uuid4())
        self.upload(operationID=operation)
        status, _ = self.f.request(token=self.f.tokens['Field Technician'], path='/api/documents', method='POST', payload={
            'operationID': operation, 'filename': 'Report.pdf', 'contentType': 'application/pdf',
            'kind': 'service_report', 'dataBase64': base64.b64encode(b'original-file').decode()})
        self.assertEqual(status, 409)
        with backend.db() as connection:
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM documents').fetchone()[0], 1)

    def test_all_operation_evidence_is_immutable(self):
        self.upload(operationID=str(uuid.uuid4()))
        for column in ('upload_operation_id', 'upload_actor_email', 'upload_request_sha256'):
            with self.assertRaises(sqlite3.IntegrityError), backend.db() as connection:
                connection.execute('UPDATE documents SET ' + column + '=?', ('changed',))

    def test_rotation_freeze_covers_new_get_and_existing_post(self):
        operation = str(uuid.uuid4())
        with backend.storage_rotation_gate().exclusive():
            status, body = self.f.request(token=self.f.tokens['Admin'], path='/api/document-uploads/' + operation)
            self.assertEqual((status, body['code']), (503, 'storage_rotation_paused'))
            self.assertEqual(self.upload(operationID=operation)[0], 503)
        with backend.db() as connection:
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM documents').fetchone()[0], 0)

    def test_recovery_operation_and_query_are_redacted_in_access_log(self):
        handler = backend.GunnAireBackendHandler.__new__(backend.GunnAireBackendHandler)
        operation = str(uuid.uuid4())
        with mock.patch.object(handler, 'address_string', return_value='127.0.0.1'), mock.patch('builtins.print') as output:
            handler.log_message('%s', 'GET /api/document-uploads/' + operation + '?customer=private HTTP/1.1')
        rendered = output.call_args.args[0]
        self.assertIn('/api/document-uploads/[redacted]', rendered)
        self.assertNotIn(operation, rendered)
        self.assertNotIn('private', rendered)

    def crashed_upload(self, phase, operation):
        script = r'''
import os, sys
from pathlib import Path
from http.server import ThreadingHTTPServer
from Backend import gunnaire_backend as b
b.DATA_ROOT=Path(sys.argv[1]); b.DB_PATH=Path(sys.argv[2]); b.STORAGE_ROOT=Path(sys.argv[3])
b.AUTH_MODE='google-id-token'; b.PRIMARY_ADMIN_EMAIL='owner@gunnaire.com'
b.initialize_database()
if sys.argv[4]=='after-commit':
    original=b.GunnAireBackendHandler.write_json
    def crash(self,payload,status=200,**kwargs):
        if self.path=='/api/documents' and int(status)==201: os._exit(23)
        return original(self,payload,status=status,**kwargs)
    b.GunnAireBackendHandler.write_json=crash
else:
    original=b.document_storage.write_document_bytes
    def crash(*args,**kwargs):
        original(*args,**kwargs)
        os._exit(23)
    b.document_storage.write_document_bytes=crash
server=ThreadingHTTPServer(('127.0.0.1',0),b.GunnAireBackendHandler)
print(server.server_port,flush=True)
server.serve_forever()
'''
        child = subprocess.Popen([sys.executable, '-u', '-c', script, str(backend.DATA_ROOT),
                                  str(backend.DB_PATH), str(backend.STORAGE_ROOT), phase],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        original_url = self.f.base_url
        try:
            import select
            self.assertTrue(select.select([child.stdout], [], [], 10)[0], 'Child failed to start')
            port = int(child.stdout.readline().strip())
            self.f.base_url = f'http://127.0.0.1:{port}'
            with self.assertRaises((OSError, http.client.HTTPException)):
                self.upload(operationID=operation)
            self.assertEqual(child.wait(timeout=10), 23)
        finally:
            self.f.base_url = original_url
            if child.poll() is None:
                child.kill()
                child.wait(timeout=10)
            child.stdout.close()
            child.stderr.close()

    def test_process_exit_after_commit_recovers_without_duplicate(self):
        operation = str(uuid.uuid4())
        self.crashed_upload('after-commit', operation)
        status, recovered = self.f.request(token=self.f.tokens['Admin'], path='/api/document-uploads/' + operation)
        self.assertEqual(status, 200)
        original_id = recovered['document']['id']
        self.assertEqual(self.upload(operationID=operation)[1]['id'], original_id)
        with backend.db() as connection:
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM documents').fetchone()[0], 1)
        self.assertEqual(len([p for p in backend.STORAGE_ROOT.rglob('*') if p.is_file()]), 1)

    def test_process_exit_before_commit_is_absent_and_safe_to_retry(self):
        operation = str(uuid.uuid4())
        self.crashed_upload('before-commit', operation)
        files = [p for p in backend.STORAGE_ROOT.rglob('*') if p.is_file()]
        self.assertEqual(len(files), 1)
        status, recovered = self.f.request(token=self.f.tokens['Admin'], path='/api/document-uploads/' + operation)
        self.assertEqual((status, recovered['document']), (200, None))
        self.assertEqual(self.upload(operationID=operation)[0], 201)
        with backend.db() as connection:
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM documents').fetchone()[0], 1)
        # A pre-commit crash leaves unreferenced bytes; never delete unknown files.
        self.assertEqual(files[0].read_bytes(), b'original-file')
