"""Large document buffers must reuse bounded allocator threads across requests."""
import hashlib
from pathlib import Path
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from unittest import mock
import unittest
from Backend import gunnaire_backend as backend, document_storage as storage

class DocumentAllocationTests(unittest.TestCase):
    def test_uploads_reuse_one_allocator_across_distinct_handler_threads(self):
        barrier=threading.Barrier(4);callers=[];workers=[];guard=threading.Lock()
        class Handler:
            def _store_document(self):workers.append(threading.get_ident())
            def write_json(self,*args,**kwargs):raise AssertionError('Unexpected overload')
        def request(index):
            callers.append(threading.get_ident());barrier.wait()
            with guard:backend.GunnAireBackendHandler.store_document(Handler())
        with ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(request,range(4)))
        self.assertEqual(len(set(callers)),4)
        self.assertEqual(len(set(workers)),1)
        self.assertTrue(set(callers).isdisjoint(workers))

    def test_retained_reads_reuse_allocator_but_still_prove_exact_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);path=root/'file';data=b'synthetic';path.write_bytes(data)
            barrier=threading.Barrier(4);workers=[];callers=[];original=storage.io.BytesIO
            def buffer(*args,**kwargs):workers.append(threading.get_ident());return original(*args,**kwargs)
            def read(index):
                callers.append(threading.get_ident());barrier.wait()
                return storage.read_document(root,path,expected_bytes=len(data),expected_sha256=hashlib.sha256(data).hexdigest())
            with mock.patch.object(storage.io,'BytesIO',side_effect=buffer),ThreadPoolExecutor(max_workers=4) as pool:
                self.assertEqual(list(pool.map(read,range(4))),[data]*4)
            self.assertEqual(len(set(workers)),1)
            self.assertTrue(set(callers).isdisjoint(workers))

    def test_lane_admits_before_submission_and_recovers_after_exception(self):
        from Backend.document_allocation import AllocationLane
        lane=AllocationLane('synthetic-test');entered=threading.Event();release=threading.Event();second_started=threading.Event()
        def first():entered.set();release.wait(5);raise ValueError('synthetic')
        def second():second_started.set();return 'done'
        with mock.patch.object(lane._worker,'submit',wraps=lane._worker.submit) as submit,ThreadPoolExecutor(max_workers=2) as callers:
            one=callers.submit(lane.run,first);self.assertTrue(entered.wait(5))
            two=callers.submit(lane.run,second)
            self.assertFalse(second_started.wait(.05));self.assertEqual(submit.call_count,1)
            release.set()
            with self.assertRaises(ValueError):one.result(timeout=5)
            self.assertEqual(two.result(timeout=5),'done');self.assertEqual(submit.call_count,2)
        lane._worker.shutdown()

    def test_interrupt_waits_for_worker_before_releasing_admission_and_rotation(self):
        import json,subprocess,sys
        code='''import json,os,signal,tempfile,threading
from pathlib import Path
from Backend.document_allocation import AllocationLane
from Backend.rotation_gate import RotationGate,Paused
lane=AllocationLane('synthetic-interrupt');entered=threading.Event();release=threading.Event();finished=threading.Event();result={}
def operation():
 entered.set()
 if not release.wait(5):raise RuntimeError('Synthetic timeout')
 finished.set()
with tempfile.TemporaryDirectory() as directory:
 gate=RotationGate(Path(directory))
 def interrupt():
  entered.wait(5);os.kill(os.getpid(),signal.SIGINT)
  threading.Event().wait(.05)
  acquired=lane._slot.acquire(blocking=False);result['prematureSlot']=acquired
  if acquired:lane._slot.release()
  try:
   with gate.exclusive(timeout=.1):result['earlyDrain']=not finished.is_set()
  except Paused:result['earlyDrain']=False
  finally:release.set()
 driver=threading.Thread(target=interrupt);driver.start()
 try:
  with gate.operation():lane.run(operation)
 except KeyboardInterrupt:result['finishedWhenInterrupted']=finished.is_set()
 finally:release.set();driver.join(5);lane._worker.shutdown()
print(json.dumps(result))
'''
        completed=subprocess.run([sys.executable,'-c',code],capture_output=True,text=True,check=True,timeout=15)
        self.assertEqual(json.loads(completed.stdout),{'prematureSlot':False,'earlyDrain':False,'finishedWhenInterrupted':True})

    def test_interrupted_submission_never_starts_unowned_operation(self):
        from Backend.document_allocation import AllocationLane
        lane=AllocationLane('synthetic-submit-interrupt');called=[];original=lane._worker.submit
        def interrupted(*args,**kwargs):
            original(*args,**kwargs)
            raise KeyboardInterrupt()
        with mock.patch.object(lane._worker,'submit',side_effect=interrupted):
            with self.assertRaises(KeyboardInterrupt):lane.run(lambda:called.append(True))
        self.assertEqual(called,[])
        self.assertTrue(lane._slot.acquire(blocking=False));lane._slot.release()
        with self.assertRaises(RuntimeError):lane.run(lambda:None)
