"""Synthetic HTTP acceptance for the existing global freeze; no new pause state."""
import threading
import time
import unittest
import uuid
from unittest import mock
from Backend import gunnaire_backend as backend
from Backend import test_document_upload_idempotency as uploads
from Tools.upload_storage_health import report

class UploadOperatorAcceptanceTests(unittest.TestCase):
    setUp = uploads.DocumentUploadIdempotencyTests.setUp
    upload = uploads.DocumentUploadIdempotencyTests.upload
    crashed_upload = uploads.DocumentUploadIdempotencyTests.crashed_upload

    def test_pause_preserves_pending_and_committed_and_resumes_same_identity(self):
        committed_operation=str(uuid.uuid4())
        status,committed=self.upload(operationID=committed_operation);self.assertEqual(status,201)
        pending_operation=str(uuid.uuid4());self.crashed_upload('before-commit',pending_operation)
        files={str(p):p.read_bytes() for p in backend.STORAGE_ROOT.rglob('*.payload')}
        with backend.db() as c:before='\n'.join(c.iterdump())
        with backend.storage_rotation_gate().exclusive():
            for operation in (committed_operation,pending_operation):
                self.assertEqual(self.upload(operationID=operation)[0],503)
                self.assertEqual(self.f.request(token=self.f.tokens['Admin'],path='/api/document-uploads/'+operation)[0],503)
            self.assertEqual(self.upload(operationID=str(uuid.uuid4()))[0],503)
            self.assertEqual(self.f.request(path='/health')[0],200)
            self.assertEqual(report(backend.DB_PATH.resolve(),backend.STORAGE_ROOT.resolve())['status'],'paused')
            with backend.db() as c:self.assertEqual('\n'.join(c.iterdump()),before)
            self.assertEqual(files,{str(p):p.read_bytes() for p in backend.STORAGE_ROOT.rglob('*.payload')})
        self.assertEqual(self.upload(operationID=committed_operation)[1]['id'],committed['id'])
        status,resumed=self.upload(operationID=pending_operation);self.assertEqual(status,201)
        self.assertEqual(self.upload(operationID=pending_operation)[1]['id'],resumed['id'])
        with backend.db() as c:
            self.assertEqual(c.execute('SELECT COUNT(*) FROM documents').fetchone()[0],2)
            self.assertEqual(c.execute('SELECT COUNT(*) FROM document_upload_reservations_v1').fetchone()[0],0)
        self.assertEqual(files,{str(p):p.read_bytes() for p in backend.STORAGE_ROOT.rglob('*.payload')})

    def test_freeze_drains_actual_active_upload_before_entry_and_rejects_new_work(self):
        prepared=threading.Event();allow_commit=threading.Event();frozen=threading.Event();release=threading.Event()
        results=[];errors=[];original=backend.document_upload_storage.Admission.prepare
        def prepare(*args,**kw):
            path=original(*args,**kw);prepared.set()
            if not allow_commit.wait(5):raise RuntimeError('Synthetic barrier timeout')
            return path
        def upload():
            try:results.append(self.upload(operationID=str(uuid.uuid4())))
            except Exception as e:errors.append(type(e).__name__)
        def freeze():
            try:
                with backend.storage_rotation_gate().exclusive(timeout=5):
                    frozen.set()
                    if not release.wait(5):raise RuntimeError('Synthetic release timeout')
            except Exception as e:errors.append(type(e).__name__)
        writer=threading.Thread(target=upload);operator=threading.Thread(target=freeze)
        with mock.patch.object(backend.document_upload_storage.Admission,'prepare',new=prepare):
            try:
                writer.start();self.assertTrue(prepared.wait(5));operator.start()
                deadline=time.monotonic()+3
                while not backend.storage_rotation_gate().marker.exists() and time.monotonic()<deadline:time.sleep(.01)
                self.assertTrue(backend.storage_rotation_gate().marker.exists());self.assertFalse(frozen.is_set())
                self.assertEqual(self.upload(operationID=str(uuid.uuid4()))[0],503)
                metrics=report(backend.DB_PATH.resolve(),backend.STORAGE_ROOT.resolve())
                self.assertTrue(metrics['uploadWriterActive']);self.assertEqual(metrics['status'],'paused')
                allow_commit.set();self.assertTrue(frozen.wait(5));writer.join(5)
                self.assertEqual(results[0][0],201)
                with backend.db() as c:self.assertEqual(c.execute('SELECT COUNT(*) FROM documents').fetchone()[0],1)
            finally:
                allow_commit.set();release.set();writer.join(5)
                if operator.ident:operator.join(5)
        self.assertEqual(errors,[]);self.assertFalse(writer.is_alive());self.assertFalse(operator.is_alive())
        self.assertFalse(backend.storage_rotation_gate().marker.exists())
