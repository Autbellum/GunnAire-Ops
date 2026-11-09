from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import sys
import unittest
from unittest import mock

from Backend import checkpoint_wal_snapshot as checkpoint
from Backend import verify_recovery_snapshot as verifier
from Backend import test_verify_recovery_snapshot as fixtures


class WalCheckpointTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.RecoverySnapshotTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root
        self.bundle = self.root/'bundle'
        self.bundle.mkdir()
        shutil.copytree(self.fixture.storage, self.bundle/'storage')
        shutil.copyfile(self.fixture.database, self.bundle/checkpoint.DB)
        self.writer = sqlite3.connect(self.bundle/checkpoint.DB)
        self.addCleanup(self.writer.close)
        self.writer.execute('PRAGMA journal_mode=WAL')
        self.writer.execute('PRAGMA wal_autocheckpoint=0')
        self.writer.execute('UPDATE protected_records SET revision=8')
        self.writer.commit()
        self.destination = self.root/'checkpoint'

    def generate(self):
        return checkpoint.generate(self.bundle, str(self.fixture.storage), self.destination)

    def fingerprint(self):
        return {p.relative_to(self.bundle).as_posix(): (hashlib.sha256(p.read_bytes()).hexdigest(),
                p.stat().st_ino, p.stat().st_mtime_ns) for p in self.bundle.rglob('*') if p.is_file()}

    def test_committed_wal_revision_is_included_and_input_bytes_unchanged(self):
        before = self.fingerprint()
        report, code = self.generate()
        self.assertEqual(code, 0, report)
        self.assertTrue(report['recoveryReady'])
        self.assertGreater(report['capturedWalFrames'], 0)
        self.assertEqual(before, self.fingerprint())
        database = self.destination/'artifact'/checkpoint.DB
        with closing(sqlite3.connect(database)) as restored:
            self.assertEqual(restored.execute('SELECT ciphertext,revision FROM protected_records').fetchone(), (self.fixture.ciphertext, 8))
            self.assertEqual(restored.execute('PRAGMA journal_mode').fetchone(), ('delete',))
        self.assertEqual(database.read_bytes()[18:20], b'\x01\x01')
        self.assertEqual(verifier.verify(self.destination/'artifact', str(self.fixture.storage))[1], 0)
        self.assertNotIn(str(self.root), json.dumps(report))
        self.assertTrue((self.destination/'checkpoint-result.json').is_file())

    def test_historical_rows_need_review(self):
        self.writer.execute('UPDATE documents SET file_size_bytes=NULL,file_sha256=NULL')
        self.writer.commit()
        report, code = self.generate()
        self.assertEqual(code, 2, report)
        self.assertFalse(report['recoveryReady'])

    def test_pending_state_is_never_rebound(self):
        self.writer.execute('INSERT INTO document_upload_reservations_v1 VALUES(?,?,?,?,?,?,?,?)',
                            ('pending','op','actor','0'*64,10,'0'*64,1,2))
        self.writer.commit()
        report, code = self.generate()
        self.assertEqual(code, 2, report)
        self.assertEqual(report['verification']['pendingReservations'], 1)
        with closing(sqlite3.connect(self.destination/'artifact'/checkpoint.DB)) as copied:
            self.assertEqual(copied.execute('SELECT device,inode FROM document_upload_reservations_v1').fetchone(), (1,2))

    def test_missing_wal_refused_and_existing_destination_never_reused(self):
        missing = self.root/'missing'
        missing.mkdir()
        shutil.copytree(self.bundle/'storage', missing/'storage')
        shutil.copyfile(self.bundle/checkpoint.DB, missing/checkpoint.DB)
        self.assertEqual(checkpoint.generate(missing, str(self.fixture.storage), self.destination)[1], 1)
        self.assertFalse(self.destination.exists())
        self.destination.mkdir()
        marker = self.destination/'untouched'
        marker.write_bytes(b'keep')
        self.assertEqual(self.generate()[1], 1)
        self.assertEqual(marker.read_bytes(), b'keep')

    def test_truncated_and_corrupt_wal_fail_closed(self):
        wal = self.bundle/(checkpoint.DB+'-wal')
        original = wal.read_bytes()
        for corrupted in (original[:-1], original[:32], original[:-1]+bytes([original[-1]^1])):
            with self.subTest(length=len(corrupted)):
                self.destination = self.root/('failed-'+str(len(list(self.root.iterdir()))))
                wal.write_bytes(corrupted)
                report, code = self.generate()
                self.assertEqual(code, 1, report)
                self.assertFalse((self.destination/'checkpoint-result.json').exists())
        wal.write_bytes(original)

    def test_source_commit_after_capture_is_detected(self):
        original = verifier.capture
        fired = []
        def capture(*args, **kwargs):
            result = original(*args, **kwargs)
            if not fired:
                fired.append(True)
                self.writer.execute('UPDATE protected_records SET revision=9')
                self.writer.commit()
            return result
        with mock.patch.object(verifier, 'capture', side_effect=capture):
            report, code = self.generate()
        self.assertEqual(code, 1, report)
        self.assertFalse((self.destination/'checkpoint-result.json').exists())

    def test_uncommitted_tail_and_oversized_database_claim_fail_before_sqlite(self):
        wal = self.bundle/(checkpoint.DB+'-wal')
        original = wal.read_bytes()
        page_size = struct.unpack('>I', original[8:12])[0]
        offset = len(original) - page_size - 24 + 4
        for pages in (0, checkpoint.MAX_BYTES//page_size + 1):
            changed = bytearray(original)
            changed[offset:offset+4] = struct.pack('>I', pages)
            wal.write_bytes(changed)
            with self.assertRaises(verifier.Invalid):
                checkpoint.wal_frames(wal)
        wal.write_bytes(original)

    def test_document_tamper_and_extras_remain_visible(self):
        (self.bundle/'storage'/'first').write_bytes(b'tampered')
        self.assertEqual(self.generate()[1], 1)
        self.destination = self.root/'extra-checkpoint'
        (self.bundle/'storage'/'first').write_bytes(b'original')
        (self.bundle/'storage'/'extra').write_bytes(b'unknown')
        self.assertEqual(self.generate()[1], 2)

    def test_interruption_leaves_no_completion_marker(self):
        script = '''import os,sys
from Backend import checkpoint_wal_snapshot as c
def crash(*args):os._exit(23)
c.standalone=crash
c.generate(*sys.argv[1:])
'''
        result = subprocess.run([sys.executable, '-c', script, str(self.bundle), str(self.fixture.storage), str(self.destination)], capture_output=True)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertFalse((self.destination/'checkpoint-result.json').exists())
        self.assertEqual(verifier.verify(self.destination/'artifact', str(self.fixture.storage))[1], 1)
        self.assertEqual(self.generate()[1], 1)

    def test_source_symlink_and_nested_destination_rejected(self):
        (self.bundle/'storage'/'alias').symlink_to(self.fixture.storage/'first')
        self.assertEqual(self.generate()[1], 1)
        self.assertEqual(checkpoint.generate(self.bundle, str(self.fixture.storage), self.bundle/'nested')[1], 1)
        self.assertFalse((self.bundle/'nested').exists())

    def test_completion_write_failure_cannot_return_ready(self):
        original = checkpoint.durable_json
        def write(path, payload):
            if path.name == 'checkpoint-result.json':
                raise OSError('synthetic completion failure')
            return original(path, payload)
        with mock.patch.object(checkpoint, 'durable_json', side_effect=write):
            report, code = self.generate()
        self.assertEqual(code, 1)
        self.assertFalse(report['recoveryReady'])
        self.assertEqual(report['status'], 'invalid')
        self.assertFalse((self.destination/'checkpoint-result.json').exists())

    def test_destination_parent_entry_is_synced_before_success(self):
        parent_identity = (self.root.stat().st_dev, self.root.stat().st_ino)
        synced = []
        original = os.fsync
        def sync(fd):
            info = os.fstat(fd)
            synced.append((info.st_dev, info.st_ino))
            return original(fd)
        with mock.patch.object(checkpoint.os, 'fsync', side_effect=sync):
            report, code = self.generate()
        self.assertEqual(code, 0, report)
        self.assertIn(parent_identity, synced)

    def test_cli_deterministic_report(self):
        result = subprocess.run([sys.executable, str(Path(checkpoint.__file__)), '--source-bundle', str(self.bundle),
                                 '--source-storage', str(self.fixture.storage), '--destination', str(self.destination)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        self.assertTrue(json.loads(result.stdout)['recoveryReady'])
        self.assertNotIn(str(self.root), result.stdout)
