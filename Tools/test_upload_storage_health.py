import json
import os
from pathlib import Path
import unittest
from types import SimpleNamespace
from unittest import mock
from Backend import document_upload_storage as storage
from Backend import test_document_upload_storage as storage_tests
from Tools.upload_storage_health import report

class UploadHealthTests(unittest.TestCase):
    def setUp(self):
        storage_tests.UploadStorageTests.setUp(self)
        self.root=self.root.resolve();self.database=self.database.resolve()
    db = storage_tests.UploadStorageTests.db
    admission = storage_tests.UploadStorageTests.admission
    reserve = storage_tests.UploadStorageTests.reserve

    def health(self):return report(self.database,self.root,self.policy)
    def test_absent_namespace_and_existing_pending_report_without_creating_files(self):
        self.root.mkdir()
        before=set(self.root.iterdir());self.assertEqual(self.health()['status'],'ok')
        self.assertEqual(set(self.root.iterdir()),before)
        with self.admission() as admission:self.reserve(admission)
        before={str(p):p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        database_bytes=self.database.read_bytes()
        metrics=self.health();self.assertEqual(metrics['pendingCount'],1)
        self.assertEqual(self.database.read_bytes(),database_bytes)
        self.assertEqual(metrics['pendingExpectedBytes'],len(self.data))
        self.assertEqual(before,{str(p):p.read_bytes() for p in self.root.rglob('*') if p.is_file()})
        encoded=json.dumps(metrics)
        for private in ('actor',self.operation,str(self.database),str(self.root),'request'):self.assertNotIn(private,encoded)
    def test_active_writer_report_does_not_wait_or_mutate(self):
        with self.admission() as admission:
            self.reserve(admission)
            result=self.health();self.assertEqual(result['status'],'busy');self.assertFalse(result['snapshotStable'])
        self.assertEqual(self.health()['status'],'ok')
    def test_pending_cap_and_low_disk_and_inode_pressure(self):
        with self.admission() as admission:self.reserve(admission)
        self.policy=storage.Policy(free_bytes=1000,pending_bytes=len(self.data),pending_count=1)
        self.assertEqual(self.health()['status'],'pressure')
        self.policy=storage.Policy(free_bytes=1000,pending_bytes=100,pending_count=3)
        for free,inodes in ((100,100),(10**9,0)):
            with mock.patch('Tools.upload_storage_health.os.statvfs',return_value=SimpleNamespace(f_bavail=free,f_frsize=1,f_favail=inodes)):
                self.assertTrue(self.health()['capacityPressure'])
    def test_global_pause_is_visible_even_with_active_writer(self):
        with self.admission():
            (self.database.parent/'.storage-rotation-paused').write_text('synthetic')
            r=self.health();self.assertEqual(r['status'],'paused');self.assertTrue(r['uploadWriterActive'])
    def test_missing_database_bad_policy_symlink_lock_fail_without_creating(self):
        missing=self.database.parent/'missing.sqlite3'
        self.assertEqual(report(missing,self.root,self.policy)['status'],'unavailable');self.assertFalse(missing.exists())
        with self.admission():pass
        lock=self.root/storage.NAMESPACE/'.lock';lock.unlink();lock.symlink_to(self.database)
        self.assertEqual(self.health()['status'],'unavailable')
        with mock.patch.dict(os.environ,{'GUNNAIRE_UPLOAD_PENDING_COUNT':'invalid'}):
            self.assertEqual(report(self.database,self.root)['status'],'unavailable')
    def test_unknown_files_are_not_read_or_deleted(self):
        with self.admission():pass
        unknown=self.root/'unknown';unknown.write_bytes(b'uncertain original')
        self.assertEqual(self.health()['status'],'ok');self.assertEqual(unknown.read_bytes(),b'uncertain original')
    def test_corrupt_database_error_contains_no_path_or_data(self):
        self.root.mkdir();self.database.write_bytes(b'private synthetic invalid database')
        result=self.health();self.assertEqual(result,{'schema':'upload-storage-health-v1','readOnly':True,'status':'unavailable','errorCode':'upload_metrics_unavailable'})
