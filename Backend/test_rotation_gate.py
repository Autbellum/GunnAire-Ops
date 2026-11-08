import json
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock
from Backend.rotation_gate import RotationGate,Paused
from Backend import gunnaire_backend as backend


class RotationGateTests(unittest.TestCase):
    def test_marker_directory_is_synced_before_entry_and_after_removal(self):
        import os
        import stat
        with tempfile.TemporaryDirectory() as directory:
            gate = RotationGate(directory)
            observed = []
            real_fsync = os.fsync
            def sync(fd):
                if stat.S_ISDIR(os.fstat(fd).st_mode):
                    observed.append(gate.marker.exists())
                return real_fsync(fd)
            with mock.patch('Backend.rotation_gate.os.fsync', side_effect=sync):
                with gate.exclusive():
                    self.assertEqual(observed, [True])
            self.assertEqual(observed, [True, False])

    def test_cross_process_drain_waits_for_refresh_persistence(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);gate=RotationGate(root)
            with sqlite3.connect(root/'fixture.sqlite3') as c:c.execute('CREATE TABLE grant(token TEXT)');c.execute("INSERT INTO grant VALUES ('old')")
            script='''from pathlib import Path
import sqlite3,sys,time
from Backend.rotation_gate import RotationGate
root=Path(sys.argv[1])
with RotationGate(root).operation():
    (root/'remote-refreshed').touch()
    end=time.monotonic()+10
    while not (root/'allow-persist').exists():
        if time.monotonic()>end:raise SystemExit(1)
        time.sleep(.01)
    with sqlite3.connect(root/'fixture.sqlite3') as c:c.execute("UPDATE grant SET token='new'")
'''
            child=subprocess.Popen([sys.executable,'-c',script,directory])
            try:
                deadline=time.monotonic()+5
                while not (root/'remote-refreshed').exists():
                    self.assertLess(time.monotonic(),deadline);time.sleep(.01)
                acquired=threading.Event();release=threading.Event();observed=[]
                def migrate():
                    with gate.exclusive(timeout=5):
                        with sqlite3.connect(root/'fixture.sqlite3') as c:observed.append(c.execute('SELECT token FROM grant').fetchone()[0])
                        acquired.set();release.wait(5)
                thread=threading.Thread(target=migrate);thread.start()
                while not gate.marker.exists():
                    self.assertLess(time.monotonic(),deadline);time.sleep(.01)
                self.assertFalse(acquired.is_set())
                with self.assertRaises(Paused):
                    with gate.operation():self.fail('A new operation entered while draining')
                (root/'allow-persist').touch()
                self.assertTrue(acquired.wait(5));self.assertEqual(observed,['new'])
                self.assertEqual(child.wait(timeout=5),0)
                release.set();thread.join(5);self.assertFalse(thread.is_alive())
                with gate.operation():pass
            finally:
                if child.poll() is None:child.terminate();child.wait(timeout=5)

    def test_failed_drain_releases_only_owned_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            gate=RotationGate(directory)
            with gate.operation():
                with self.assertRaises(Paused):
                    with gate.exclusive(timeout=0):self.fail('Did not drain')
            self.assertFalse(gate.marker.exists())
            gate.marker.write_text('operator recovery pending')
            with self.assertRaises(FileExistsError):
                with gate.exclusive():self.fail('Adopted someone else\'s marker')
            self.assertEqual(gate.marker.read_text(),'operator recovery pending')

    def test_migration_failure_retains_freeze_for_explicit_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            gate=RotationGate(directory)
            with self.assertRaises(RuntimeError):
                with gate.exclusive():raise RuntimeError('Synthetic interrupted migration')
            self.assertTrue(gate.marker.exists())
            with self.assertRaises(Paused):
                with gate.operation():self.fail('Released an uncertain migration')

    def test_frozen_routes_workers_and_startup_do_not_mutate_or_acknowledge(self):
        from Backend.test_workspace_identity import WorkspaceIdentityTests
        fixture=WorkspaceIdentityTests();fixture.setUp();self.addCleanup(fixture.tearDown)
        with backend.db() as connection:before='\n'.join(connection.iterdump())
        with backend.storage_rotation_gate().exclusive():
            for path,method,payload in [('/api/session','GET',None),('/api/qbo/webhooks','POST',{}),
                                        ('/api/google/oauth/callback?code=fixture','GET',None),('/portal/fixture','GET',None)]:
                status,result=fixture.request(token=fixture.tokens['Admin'],path=path,method=method,payload=payload)
                self.assertEqual(status,503);self.assertEqual(result['code'],'storage_rotation_paused')
            self.assertEqual(fixture.request(path='/health')[0],200)
            with mock.patch.object(backend,'db',side_effect=AssertionError('Worker touched database')):
                sender=mock.Mock()
                self.assertEqual(backend.deliver_pending_pushes(sender=sender),0);sender.assert_not_called()
                self.assertEqual(backend.run_scheduled_backup_if_due(force=True),{'outcome':'rotation-paused'})
            with mock.patch.object(backend,'initialize_database') as initialize, \
                    mock.patch.object(backend,'start_push_delivery_worker') as push, \
                    mock.patch.object(backend,'start_backup_worker') as backup:
                with self.assertRaises(Paused):backend.main()
                initialize.assert_not_called();push.assert_not_called();backup.assert_not_called()
        with backend.db() as connection:self.assertEqual('\n'.join(connection.iterdump()),before)

if __name__=='__main__':unittest.main()
