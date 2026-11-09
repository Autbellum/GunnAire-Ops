"""Synthetic cancellation, backpressure, disconnect and worker-drain acceptance."""
import base64,json,socket,struct,threading,time,unittest,uuid
from concurrent.futures import ThreadPoolExecutor
from unittest import mock
from urllib.parse import urlparse
from Backend import gunnaire_backend as backend
from Backend.document_allocation import AllocationLane
from Backend import test_document_upload_idempotency as uploads

class AllocatorLifecycleTests(unittest.TestCase):
    def test_running_caller_cannot_cancel_and_shutdown_waits_for_owned_work(self):
        lane=AllocationLane('synthetic-lifecycle');entered=threading.Event();release=threading.Event();stopped=threading.Event()
        def operation():entered.set();release.wait(5);return 'complete'
        with ThreadPoolExecutor(max_workers=1) as callers:
            current=callers.submit(lane.run,operation);self.assertTrue(entered.wait(5))
            self.assertFalse(current.cancel())
            shutdown=threading.Thread(target=lambda:(lane._worker.shutdown(wait=True,cancel_futures=True),stopped.set()))
            shutdown.start()
            try:
                self.assertFalse(stopped.wait(.05));self.assertFalse(lane._slot.acquire(blocking=False))
            finally:release.set();shutdown.join(5)
            self.assertEqual(current.result(timeout=5),'complete');self.assertTrue(stopped.is_set())
        with self.assertRaises(RuntimeError):lane.run(lambda:None)
        self.assertTrue(lane._slot.acquire(blocking=False));lane._slot.release()

    def test_cancel_before_admission_never_submits_and_broken_pipe_releases(self):
        lane=AllocationLane('synthetic-cancel');entered=threading.Event();release=threading.Event();called=[]
        with ThreadPoolExecutor(max_workers=1) as callers:
            blocking=callers.submit(lambda:(entered.set(),release.wait(5)));self.assertTrue(entered.wait(5))
            queued=callers.submit(lane.run,lambda:called.append(True));self.assertTrue(queued.cancel())
            release.set();blocking.result(timeout=5)
        self.assertEqual(called,[])
        def broken():raise BrokenPipeError('Synthetic disconnected socket')
        with self.assertRaises(BrokenPipeError):lane.run(broken)
        self.assertEqual(lane.run(lambda:'ready'),'ready');lane._worker.shutdown()

    def test_upload_backpressure_rejects_before_body_or_worker_submission(self):
        entered=threading.Event();release=threading.Event();statuses=[]
        class First:
            def _store_document(self):entered.set();release.wait(5)
        class Excess:
            def _store_document(self):raise AssertionError('Excess body read')
            def write_json(self,payload,status):statuses.append(int(status))
        thread=threading.Thread(target=backend.GunnAireBackendHandler.store_document,args=(First(),));thread.start()
        try:
            self.assertTrue(entered.wait(5))
            with mock.patch.object(backend.DOCUMENT_UPLOAD_ALLOCATOR,'run',wraps=backend.DOCUMENT_UPLOAD_ALLOCATOR.run) as run:
                backend.GunnAireBackendHandler.store_document(Excess());run.assert_not_called()
            self.assertEqual(statuses,[503])
        finally:release.set();thread.join(5)
        self.assertFalse(thread.is_alive())

    def test_client_disconnect_keeps_rotation_guard_until_commit_and_replay(self):
        fixture=uploads.DocumentUploadIdempotencyTests();fixture.setUp();self.addCleanup(fixture.doCleanups)
        prepared=threading.Event();allow=threading.Event();frozen=threading.Event();resume=threading.Event();errors=[]
        original=backend.document_upload_storage.Admission.prepare;operation=str(uuid.uuid4())
        def prepare(*args,**kw):
            path=original(*args,**kw);prepared.set()
            if not allow.wait(5):raise RuntimeError('Synthetic barrier timeout')
            return path
        def freeze():
            try:
                with backend.storage_rotation_gate().exclusive(timeout=5):frozen.set();resume.wait(5)
            except Exception as error:errors.append(type(error).__name__)
        url=urlparse(fixture.f.base_url);connection=socket.create_connection((url.hostname,url.port),timeout=5)
        body=json.dumps(dict(filename='Report.pdf',contentType='application/pdf',kind='service_report',dataBase64=base64.b64encode(b'original-file').decode(),operationID=operation)).encode()
        headers=('POST /api/documents HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer '+fixture.f.tokens['Admin']+'\r\nContent-Type: application/json\r\nContent-Length: '+str(len(body))+'\r\nConnection: close\r\n\r\n').encode()
        operator=threading.Thread(target=freeze)
        with mock.patch.object(backend.document_upload_storage.Admission,'prepare',new=prepare):
            try:
                connection.sendall(headers+body);self.assertTrue(prepared.wait(5))
                connection.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0));connection.close()
                operator.start()
                deadline=time.monotonic()+3
                while not backend.storage_rotation_gate().marker.exists() and time.monotonic()<deadline:time.sleep(.01)
                self.assertTrue(backend.storage_rotation_gate().marker.exists());self.assertFalse(frozen.is_set())
                self.assertEqual(fixture.upload(operationID=str(uuid.uuid4()))[0],503)
                allow.set();self.assertTrue(frozen.wait(5))
                with backend.db() as c:
                    self.assertEqual(c.execute('SELECT COUNT(*) FROM documents').fetchone()[0],1)
                    self.assertEqual(c.execute('SELECT COUNT(*) FROM document_upload_reservations_v1').fetchone()[0],0)
            finally:
                connection.close();allow.set();resume.set()
                if operator.ident:operator.join(5)
        self.assertEqual(errors,[])
        status,replay=fixture.upload(operationID=operation);self.assertEqual(status,201)
        recovered=fixture.f.request(token=fixture.f.tokens['Admin'],path='/api/document-uploads/'+operation)[1]
        self.assertEqual(recovered['document']['id'],replay['id'])
