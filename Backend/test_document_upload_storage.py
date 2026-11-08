import hashlib
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid
from contextlib import contextmanager
from types import SimpleNamespace
from unittest import mock

from Backend import document_upload_storage as storage


class UploadStorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'storage'
        self.database = Path(self.temp.name) / 'fixture.sqlite3'
        with self.db() as connection:
            connection.execute('CREATE TABLE documents(id TEXT,stored_path TEXT,file_size_bytes INTEGER,file_sha256 TEXT)')
            storage.initialize(connection)
        self.data = b'original-payload'
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.operation = str(uuid.uuid4())
        self.policy = storage.Policy(free_bytes=1000, pending_bytes=100, pending_count=3)

    @contextmanager
    def db(self):
        connection = sqlite3.connect(self.database)
        connection.row_factory = sqlite3.Row
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def admission(self, policy=None):
        return storage.Admission(self.db, self.root, self.database, policy or self.policy)

    def reserve(self, admission, operation=None, actor='actor', request='request'):
        return admission.reserve(operation or self.operation, actor, request, len(self.data), self.digest)

    def test_same_operation_reuses_durable_owned_file_and_commits_atomically(self):
        with self.admission() as admission:
            row = self.reserve(admission)
            path = admission.prepare(row, self.data)
        with self.admission() as admission:
            resumed = self.reserve(admission)
            self.assertEqual(resumed, row)
            with mock.patch.object(storage, 'write_payload', side_effect=AssertionError('Rewrote complete pending bytes')):
                self.assertEqual(admission.prepare(resumed, self.data), path)
            with self.db() as connection:
                connection.execute('INSERT INTO documents VALUES(?,?,?,?)', (row['id'], str(path), len(self.data), self.digest))
                admission.complete(row, connection)
        with self.db() as connection:
            self.assertEqual(connection.execute(f'SELECT COUNT(*) FROM {storage.TABLE}').fetchone()[0], 0)
        self.assertEqual(path.read_bytes(), self.data)

    def test_database_rollback_retains_reservation_and_bytes(self):
        with self.admission() as admission:
            row = self.reserve(admission)
            path = admission.prepare(row, self.data)
            with self.assertRaises(RuntimeError), self.db() as connection:
                connection.execute('INSERT INTO documents VALUES(?,?,?,?)', (row['id'], str(path), len(self.data), self.digest))
                admission.complete(row, connection)
                raise RuntimeError('before commit')
        with self.db() as connection:
            self.assertEqual(connection.execute(f'SELECT COUNT(*) FROM {storage.TABLE}').fetchone()[0], 1)
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM documents').fetchone()[0], 0)
        self.assertEqual(path.read_bytes(), self.data)

    def test_partial_write_retries_same_inode_and_exact_prefix(self):
        def partial(fd, data):
            os.write(fd, data[:5]); os.fsync(fd)
            raise OSError('interrupted')
        with self.admission() as admission:
            row = self.reserve(admission)
            with mock.patch.object(storage, 'write_payload', partial), self.assertRaises(storage.StorageAdmissionError):
                admission.prepare(row, self.data)
            inode = admission.path(row).stat().st_ino
        with self.admission() as admission:
            row = self.reserve(admission)
            path = admission.prepare(row, self.data)
            self.assertEqual(path.stat().st_ino, inode)
            self.assertEqual(path.read_bytes(), self.data)

    def test_corrupted_partial_or_complete_file_is_never_overwritten(self):
        with self.admission() as admission:
            row = self.reserve(admission); path = admission.prepare(row, self.data)
        for bad in (b'wrong', b'X' * len(self.data), self.data + b'extra'):
            path.write_bytes(bad)
            with self.admission() as admission, self.assertRaises(storage.StorageAdmissionError):
                row = self.reserve(admission); admission.prepare(row, self.data)
            self.assertEqual(path.read_bytes(), bad)

    def test_other_actor_and_changed_request_cannot_adopt_pending_operation(self):
        with self.admission() as admission:
            row = self.reserve(admission); path = admission.prepare(row, self.data)
        for actor, request in [('other', 'request'), ('actor', 'changed')]:
            with self.admission() as admission, self.assertRaises(storage.StorageAdmissionError) as error:
                self.reserve(admission, actor=actor, request=request)
            self.assertEqual(error.exception.status, 409)
        self.assertEqual(path.read_bytes(), self.data)

    def test_low_disk_refuses_before_reservation_or_payload(self):
        with self.admission() as admission:
            with mock.patch.object(storage.os, 'fstatvfs', return_value=SimpleNamespace(f_bavail=10, f_frsize=1)):
                with self.assertRaises(storage.StorageAdmissionError):
                    self.reserve(admission)
        with self.db() as connection:
            self.assertEqual(connection.execute(f'SELECT COUNT(*) FROM {storage.TABLE}').fetchone()[0], 0)
        self.assertEqual(list(self.root.rglob('*.payload')), [])

    def test_unwritten_reservations_are_charged_against_free_space(self):
        with self.admission() as admission:
            self.reserve(admission)
            available = self.policy.free_bytes + storage.METADATA_BYTES + len(self.data)
            with mock.patch.object(storage.os, 'fstatvfs', return_value=SimpleNamespace(f_bavail=available, f_frsize=1)):
                self.reserve(admission)  # Existing promise fits, a second does not.
                with self.assertRaises(storage.StorageAdmissionError):
                    self.reserve(admission, operation=str(uuid.uuid4()))

    def test_pending_count_and_bytes_cap_new_intents_but_allow_existing_recovery(self):
        for policy in (storage.Policy(1000, len(self.data), 3), storage.Policy(1000, 100, 1)):
            with self.admission(policy) as admission:
                row = self.reserve(admission)
                with self.assertRaises(storage.StorageAdmissionError):
                    self.reserve(admission, operation=str(uuid.uuid4()))
                self.assertEqual(self.reserve(admission)['id'], row['id'])

    def test_committed_references_are_never_rewritten_or_removed(self):
        with self.admission() as admission:
            row = self.reserve(admission); path = admission.prepare(row, self.data)
            with self.db() as connection:
                connection.execute('INSERT INTO documents VALUES(?,?,?,?)', ('other-id', str(path), len(self.data), self.digest))
            with self.assertRaises(storage.StorageAdmissionError):
                admission.prepare(row, self.data)
            with self.assertRaises(storage.StorageAdmissionError):
                self.reserve(admission)
        self.assertEqual(path.read_bytes(), self.data)

    def test_unproven_file_after_reservation_is_preserved(self):
        with self.admission() as admission:
            row = self.reserve(admission)
            path = admission.path(row); path.write_bytes(b'unknown'); path.chmod(0o600)
            with self.assertRaises(storage.StorageAdmissionError):
                admission.prepare(row, self.data)
        self.assertEqual(path.read_bytes(), b'unknown')

    def test_unknown_historical_file_is_not_adopted_or_deleted(self):
        self.root.mkdir(); unknown = self.root/'untracked.pdf'; unknown.write_bytes(b'keep')
        with self.admission() as admission:
            row = self.reserve(admission); admission.prepare(row, self.data)
        self.assertEqual(unknown.read_bytes(), b'keep')

    def test_payload_symlink_hardlink_and_replaced_inode_fail_closed(self):
        with self.admission() as admission:
            row = self.reserve(admission); path = admission.prepare(row, self.data)
        held = self.root/'held'; path.rename(held)
        outside = Path(self.temp.name)/'outside'; outside.write_bytes(b'outside')
        for kind in ('symlink', 'hardlink', 'replacement'):
            if kind == 'symlink': path.symlink_to(outside)
            elif kind == 'hardlink': os.link(held, path)
            else: path.write_bytes(self.data); path.chmod(0o600)
            with self.admission() as admission, self.assertRaises(storage.StorageAdmissionError):
                self.reserve(admission)
            self.assertEqual(outside.read_bytes(), b'outside'); self.assertEqual(held.read_bytes(), self.data)
            path.unlink()

    def test_namespace_symlink_and_directory_swap_are_rejected(self):
        self.root.mkdir(); outside=Path(self.temp.name)/'outside'; outside.mkdir()
        (self.root/storage.NAMESPACE).symlink_to(outside, target_is_directory=True)
        with self.assertRaises(storage.StorageAdmissionError):
            with self.admission(): pass
        (self.root/storage.NAMESPACE).unlink()
        with self.admission() as admission:
            row=self.reserve(admission)
            (self.root/storage.NAMESPACE).rename(self.root/'moved')
            (self.root/storage.NAMESPACE).symlink_to(outside, target_is_directory=True)
            with self.assertRaises(storage.StorageAdmissionError): admission.prepare(row,self.data)
        self.assertEqual(list(outside.iterdir()), [])

    def test_cross_process_lock_refuses_concurrent_admission(self):
        code = '''import os,fcntl,sys
fd=os.open(sys.argv[1],os.O_RDWR)
try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError: sys.exit(17)
sys.exit(1)
'''
        with self.admission():
            result=subprocess.run([sys.executable,'-c',code,str(self.root/storage.NAMESPACE/'.lock')], timeout=10)
            self.assertEqual(result.returncode,17)
        with self.admission(): pass

    def test_policy_invalid_values_fail_closed(self):
        for raw in ('0','-1','1_000','invalid','999999999999999999999999'):
            with mock.patch.dict(os.environ, {'GUNNAIRE_UPLOAD_FREE_RESERVE_BYTES':raw}), self.assertRaises(storage.StorageAdmissionError):
                storage.Policy.from_environment()

    def test_reservation_before_file_creation_resumes_without_new_identity(self):
        with self.admission() as admission:
            row = self.reserve(admission)
            self.assertFalse(admission.path(row).exists())
        with self.admission() as admission:
            resumed = self.reserve(admission)
            self.assertEqual(resumed['id'], row['id'])
            self.assertEqual(admission.prepare(resumed, self.data).read_bytes(), self.data)

    def test_lock_symlink_and_lock_replacement_refuse_admission(self):
        with self.admission(): pass
        lock = self.root/storage.NAMESPACE/'.lock'
        outside = Path(self.temp.name)/'outside'; outside.write_bytes(b'keep')
        lock.unlink(); lock.symlink_to(outside)
        with self.assertRaises(storage.StorageAdmissionError):
            with self.admission(): pass
        self.assertEqual(outside.read_bytes(), b'keep')
        lock.unlink()
        with self.admission() as admission:
            lock.rename(lock.with_name('held-lock'))
            lock.write_bytes(b''); lock.chmod(0o600)
            with self.assertRaises(storage.StorageAdmissionError): self.reserve(admission)

    def test_reservation_path_components_cannot_escape_namespace(self):
        with self.admission() as admission:
            row = self.reserve(admission)
            row['id'] = '../outside'
            with self.assertRaises(storage.StorageAdmissionError): admission.prepare(row, self.data)
        self.assertFalse((self.root/'outside').exists())

    def test_commit_binding_failure_rolls_back_without_destroying_pending_file(self):
        with self.admission() as admission:
            row = self.reserve(admission); path = admission.prepare(row, self.data)
            with self.assertRaises(storage.StorageAdmissionError), self.db() as connection:
                connection.execute('INSERT INTO documents VALUES(?,?,?,?)', (row['id'], str(path), len(self.data), '0'*64))
                admission.complete(row, connection)
        with self.db() as connection:
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM documents').fetchone()[0], 0)
            self.assertEqual(connection.execute(f'SELECT COUNT(*) FROM {storage.TABLE}').fetchone()[0], 1)
        self.assertEqual(path.read_bytes(), self.data)

    def test_pending_identity_fields_are_immutable_but_repeat_initialization_preserves_row(self):
        with self.admission() as admission:
            row = self.reserve(admission)
        with self.db() as connection:
            storage.initialize(connection)
            self.assertEqual(dict(connection.execute(f'SELECT * FROM {storage.TABLE}').fetchone()), row)
        for field, value in (('id', str(uuid.uuid4())), ('operation_id', str(uuid.uuid4())), ('actor', 'other'),
                             ('request_sha256', 'other'), ('expected_bytes', 999), ('file_sha256', '0'*64)):
            with self.assertRaises(sqlite3.IntegrityError), self.db() as connection:
                connection.execute(f'UPDATE {storage.TABLE} SET {field}=?', (value,))

    def test_separate_database_filesystem_reserve_is_also_required(self):
        with self.admission() as admission:
            real_stat = os.fstat
            held = {admission.root_fd, admission.directory_fd, admission.lock_fd}
            def stat_device(fd):
                value = real_stat(fd)
                return value if fd in held else SimpleNamespace(st_dev=value.st_dev+1)
            def space(fd):
                return SimpleNamespace(f_bavail=10**9 if fd == admission.directory_fd else 0, f_frsize=1)
            with mock.patch.object(storage.os, 'fstat', side_effect=stat_device), mock.patch.object(storage.os, 'fstatvfs', side_effect=space):
                with self.assertRaises(storage.StorageAdmissionError) as error:
                    self.reserve(admission)
            self.assertIn('Database disk reserve', str(error.exception))
        with self.db() as connection:
            self.assertEqual(connection.execute(f'SELECT COUNT(*) FROM {storage.TABLE}').fetchone()[0], 0)


if __name__ == '__main__': unittest.main()
