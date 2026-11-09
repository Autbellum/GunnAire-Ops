"""Deterministic allocation regressions for verification-only upload paths."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

class UploadVerificationMemoryTests(unittest.TestCase):
    def test_proof_only_maximum_upload_does_not_materialize_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'synthetic';block=b'm'*1024**2;h=hashlib.sha256()
            with path.open('wb') as f:
                for _ in range(25):f.write(block);h.update(block)
            code='''import json,sys,tracemalloc
from pathlib import Path
from Backend import document_storage as s
verify=getattr(s,'verify_document',s.read_document)
tracemalloc.start()
verify(Path(sys.argv[1]),sys.argv[2],expected_bytes=25*1024**2,expected_sha256=sys.argv[3])
print(json.dumps({'peak':tracemalloc.get_traced_memory()[1]}))
'''
            r=subprocess.run([sys.executable,'-c',code,directory,str(path),h.hexdigest()],capture_output=True,text=True,check=True)
            measured=json.loads(r.stdout)
            self.assertLess(measured['peak'],2*1024**2,measured)

    def test_replay_does_not_retain_base64_string_during_file_proof(self):
        import inspect,uuid
        from unittest import mock
        from Backend import gunnaire_backend as b
        from Backend import test_document_upload_idempotency as cases
        case=cases.DocumentUploadIdempotencyTests();case.setUp();self.addCleanup(case.doCleanups)
        operation=str(uuid.uuid4());payload=b'z'*1024**2
        self.assertEqual(case.upload(operationID=operation,payload=payload)[0],201)
        observations=[];original=b.document_storage.read_document
        def observe(*args,**kw):
            frame=inspect.currentframe()
            while frame and frame.f_code.co_name!='_store_document':frame=frame.f_back
            if frame:
                local=frame.f_locals
                observations.append(max(len(local.get('data_base64','')),len(local.get('payload',{}).get('dataBase64',''))))
            frame=None
            local=None
            return original(*args,**kw)
        with mock.patch.object(b.document_storage,'read_document',new=observe):
            self.assertEqual(case.upload(operationID=operation,payload=payload)[0],201)
        self.assertEqual(observations,[0])

    def test_streaming_proof_preserves_corruption_path_and_midread_checks(self):
        import os
        from unittest import mock
        from Backend import document_storage as s
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);path=root/'original';data=b'original-bytes';path.write_bytes(data)
            digest=hashlib.sha256(data).hexdigest()
            def verify(p=path,sha=digest):return s.verify_document(root,p,expected_bytes=len(data),expected_sha256=sha)
            original=os.read
            with mock.patch.object(os,'read',side_effect=lambda fd,n:original(fd,min(n,2))):self.assertIsNone(verify())
            with self.assertRaises(s.DocumentReadError) as error:verify(sha='0'*64)
            self.assertEqual(error.exception.status,409)
            alias=root/'alias';alias.symlink_to(path)
            with self.assertRaises(s.DocumentReadError) as error:verify(alias)
            self.assertEqual(error.exception.status,403)
            changed=False
            def mutate(fd,n):
                nonlocal changed
                result=original(fd,n)
                if not changed:path.write_bytes(b'replacement!!');changed=True
                return result
            with mock.patch.object(os,'read',side_effect=mutate),self.assertRaises(s.DocumentReadError) as error:verify()
            self.assertEqual(error.exception.status,409)
