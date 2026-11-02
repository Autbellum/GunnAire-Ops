import hashlib
import http.client
import json
import socket
import sqlite3
import unittest
import uuid
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
