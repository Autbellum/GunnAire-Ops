"""Synthetic DB-first backup races and non-mutating recovery certification."""
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

from Backend import backup_backend as backup
from Backend import verify_recovery_snapshot as verifier


class RecoverySnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        # macOS /var is a symlink. Real fixtures use the canonical ancestor.
        self.root = Path(self.temp.name).resolve()
        self.storage = self.root / 'source'
        self.storage.mkdir()
        self.database = self.root / 'source.sqlite3'
        self.artifact = self.root / 'artifact'
        self.sql('CREATE TABLE documents(id TEXT PRIMARY KEY,stored_path TEXT,file_size_bytes INTEGER,file_sha256 TEXT)')
        self.sql('CREATE TABLE document_upload_reservations_v1(id TEXT PRIMARY KEY,device INTEGER,inode INTEGER)')
        self.sql('CREATE TABLE protected_records(ciphertext BLOB, revision INTEGER)')
        self.ciphertext = b'v2:synthetic-opaque-ciphertext\x00\xff'
        self.sql('INSERT INTO protected_records VALUES(?,7)', (self.ciphertext,))
        self.document('first', b'original')

    def sql(self, query, values=(), database=None):
        with closing(sqlite3.connect(database or self.database)) as connection, connection:
            return connection.execute(query, values).fetchall()

    def document(self, name, data, proof=True):
        path = self.storage / name
        path.write_bytes(data)
        self.sql('INSERT INTO documents VALUES(?,?,?,?)', (name, str(path), len(data) if proof else None,
                 hashlib.sha256(data).hexdigest() if proof else None))
        return path

    def make(self):
        backup.create_backup(self.database, self.storage, self.artifact)

    def refresh_manifest(self):
        manifest = {'schemaVersion': 1, 'database': backup.file_record(self.artifact / backup.DATABASE_FILENAME, self.artifact),
                    'documents': [backup.file_record(p, self.artifact) for p in sorted((self.artifact/'storage').rglob('*')) if p.is_file()]}
        (self.artifact/'manifest.json').write_text(json.dumps(manifest))

    def check(self, code):
        report, actual = verifier.verify(self.artifact, str(self.storage))
        self.assertEqual(actual, code, report)
        self.assertEqual(report['recoveryReady'], code == 0)
        text = json.dumps(report)
        self.assertNotIn(str(self.root), text)
        self.assertNotIn('original', text.replace('originalIntegrityProven', ''))
        return report

    def test_valid_committed_snapshot_preserves_input_and_ciphertext(self):
        self.make()
        before = {str(p): (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns) for p in self.artifact.rglob('*') if p.is_file()}
        report = self.check(0)
        self.assertEqual(report['provenDocuments'], 1)
        self.assertTrue(report['originalIntegrityProven'])
        after = {str(p): (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns) for p in self.artifact.rglob('*') if p.is_file()}
        self.assertEqual(before, after)
        self.assertEqual(self.sql('SELECT ciphertext,revision FROM protected_records', database=self.artifact/backup.DATABASE_FILENAME), [(self.ciphertext, 7)])

    def test_historical_rows_need_review_even_with_valid_manifest(self):
        self.document('history', b'unknown origin', proof=False)
        self.make()
        report = self.check(2)
        self.assertTrue(report['byteCopyConsistent'])
        self.assertFalse(report['originalIntegrityProven'])
        self.assertEqual(report['historicalUnverifiedDocuments'], 1)

    def test_missing_reference_rejected_even_after_manifest_rebuilt(self):
        self.make()
        (self.artifact/'storage'/'first').unlink()
        self.refresh_manifest()
        self.assertTrue(self.check(1)['byteCopyConsistent'])

    def test_tamper_rejected_even_after_manifest_rebuilt(self):
        self.make()
        (self.artifact/'storage'/'first').write_bytes(b'tampered')
        self.refresh_manifest()
        self.check(1)

    def test_post_snapshot_commit_is_extra_not_silently_adopted(self):
        original = backup.sqlite_integrity
        errors = []
        def concurrent_upload():
            try:
                self.document('later', b'concurrent upload')
            except BaseException as error:
                errors.append(error)
        def after_snapshot(path):
            original(path)
            if path.parent == self.artifact and not (self.storage/'later').exists():
                writer = threading.Thread(target=concurrent_upload)
                writer.start()
                writer.join(timeout=5)
                self.assertFalse(writer.is_alive())
                self.assertEqual(errors, [])
        with mock.patch.object(backup, 'sqlite_integrity', side_effect=after_snapshot):
            self.make()
        report = self.check(2)
        self.assertEqual(report['committedDocuments'], 1)
        self.assertEqual(report['unreferencedFiles'], 1)
        self.assertEqual(self.sql('SELECT COUNT(*) FROM documents')[0][0], 2)

    def test_pending_to_committed_after_snapshot_stays_uncertain(self):
        pending = self.storage/'pending'
        pending.write_bytes(b'partial')
        info = pending.stat()
        self.sql('INSERT INTO document_upload_reservations_v1 VALUES(?,?,?)', ('pending', info.st_dev, info.st_ino))
        original = backup.sqlite_integrity
        def after_snapshot(path):
            original(path)
            if self.sql('SELECT COUNT(*) FROM document_upload_reservations_v1')[0][0]:
                pending.write_bytes(b'completed')
                self.sql('INSERT INTO documents VALUES(?,?,?,?)', ('pending', str(pending), 9, hashlib.sha256(b'completed').hexdigest()))
                self.sql('DELETE FROM document_upload_reservations_v1')
        with mock.patch.object(backup, 'sqlite_integrity', side_effect=after_snapshot):
            self.make()
        self.assertNotEqual((self.artifact/'storage'/'pending').stat().st_ino, info.st_ino)
        report = self.check(2)
        self.assertEqual(report['pendingReservations'], 1)
        self.assertEqual(report['unreferencedFiles'], 1)

    def test_pending_without_file_is_not_ready(self):
        self.sql('INSERT INTO document_upload_reservations_v1 VALUES(?,?,?)', ('pending', None, None))
        self.make()
        self.assertEqual(self.check(2)['pendingReservations'], 1)

    def test_empty_known_lock_is_infrastructure_not_payload(self):
        namespace = self.storage/'.document-upload-v1'
        namespace.mkdir()
        (namespace/'.lock').touch()
        self.make()
        self.assertEqual(self.check(0)['infrastructureFiles'], 1)
        (self.artifact/'storage'/namespace.name/'.lock').write_bytes(b'unknown')
        self.refresh_manifest()
        self.check(2)

    def test_partial_crash_artifact_and_truncated_database_rejected(self):
        self.make()
        manifest = self.artifact/'manifest.json'
        saved = manifest.read_bytes()
        manifest.unlink()
        self.check(1)
        manifest.write_bytes(saved)
        (self.artifact/backup.DATABASE_FILENAME).write_bytes(b'partial database')
        self.refresh_manifest()
        self.check(1)

    def test_process_crash_before_manifest_cannot_certify_checkpoint(self):
        script = '''import os,sys
from pathlib import Path
from Backend import backup_backend as b
original=b.copy_document
def crash(source,target):
    original(source,target)
    os._exit(19)
b.copy_document=crash
b.create_backup(*map(Path,sys.argv[1:]))
'''
        result = subprocess.run([sys.executable, '-c', script, str(self.database), str(self.storage), str(self.artifact)], capture_output=True)
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertTrue((self.artifact/backup.DATABASE_FILENAME).is_file())
        self.assertFalse((self.artifact/'manifest.json').exists())
        self.check(1)

    def test_special_file_and_database_sidecar_are_rejected(self):
        self.make()
        special = self.artifact/'storage'/'fifo'
        os.mkfifo(special)
        self.check(1)
        special.unlink()
        (self.artifact/(backup.DATABASE_FILENAME+'-wal')).write_bytes(b'incomplete snapshot')
        self.check(1)

    def test_unsafe_database_paths_rejected_without_following(self):
        self.make()
        for unsafe in ('/outside/private', str(self.storage)+'/../private', str(self.storage)+'/./first', 'first'):
            with self.subTest(path=unsafe):
                self.sql('UPDATE documents SET stored_path=?', (unsafe,), self.artifact/backup.DATABASE_FILENAME)
                self.refresh_manifest()
                self.check(1)

    def test_symlink_hardlink_and_symlink_ancestor_rejected(self):
        self.make()
        copied = self.artifact/'storage'/'first'
        copied.unlink()
        copied.symlink_to(self.storage/'first')
        self.check(1)
        copied.unlink()
        os.link(self.storage/'first', copied)
        self.check(1)
        copied.unlink()
        copied.write_bytes(b'original')
        alias = self.root/'alias'
        alias.symlink_to(self.artifact, target_is_directory=True)
        self.assertEqual(verifier.verify(alias, str(self.storage))[1], 1)

    def test_manifest_path_attack_and_database_substitution_rejected(self):
        self.make()
        manifest = self.artifact/'manifest.json'
        original = json.loads(manifest.read_text())
        for path in ('../source.sqlite3', 'storage/first'):
            changed = dict(original)
            changed['database'] = dict(original['database'], path=path)
            manifest.write_text(json.dumps(changed))
            self.check(1)

    def test_resource_bounds(self):
        self.make()
        for limits in ({'max_bytes': 1}, {'max_entries': 1}):
            report, code = verifier.verify(self.artifact, str(self.storage), **limits)
            self.assertEqual(code, 1)
            self.assertFalse(report['recoveryReady'])

    def test_deep_malformed_manifest_fails_with_value_free_report(self):
        self.make()
        (self.artifact/'manifest.json').write_text('[' * 2000 + '0' + ']' * 2000)
        self.check(1)

    def test_file_changed_during_capture_fails_closed(self):
        self.make()
        target = self.artifact/'storage'/'first'
        original = verifier.os.read
        changed = []
        def read(fd, length):
            chunk = original(fd, length)
            if chunk == b'original' and not changed:
                target.write_bytes(b'altered!')
                changed.append(True)
            return chunk
        with mock.patch.object(verifier.os, 'read', side_effect=read):
            self.check(1)
        self.assertTrue(changed)

    def test_partial_proof_and_duplicate_reference_rejected(self):
        self.make()
        copied_db = self.artifact/backup.DATABASE_FILENAME
        self.sql('UPDATE documents SET file_sha256=NULL', database=copied_db)
        self.refresh_manifest()
        self.check(1)
        self.sql('UPDATE documents SET file_sha256=?', (hashlib.sha256(b'original').hexdigest(),), copied_db)
        self.sql("INSERT INTO documents SELECT 'duplicate',stored_path,file_size_bytes,file_sha256 FROM documents", database=copied_db)
        self.refresh_manifest()
        self.check(1)

    def test_real_initializer_and_copy_rehearsal_preserve_committed_state(self):
        from Backend import gunnaire_backend as backend
        # Minimal pre-contract schema becomes the actual candidate schema locally.
        self.sql('DROP TABLE document_upload_reservations_v1')
        before = self.sql('SELECT * FROM documents')
        with mock.patch.object(backend, 'DB_PATH', self.database):
            backend.initialize_database()
            backend.initialize_database()
        self.assertEqual(self.sql('SELECT id,stored_path,file_size_bytes,file_sha256 FROM documents'), before)
        self.make()
        self.check(0)
        restored = self.root/'restored'
        backup.restore_drill(self.artifact, restored)
        self.assertEqual(self.sql('SELECT ciphertext,revision FROM protected_records', database=restored/backup.DATABASE_FILENAME), [(self.ciphertext, 7)])
        with mock.patch.object(backend, 'DB_PATH', restored/backup.DATABASE_FILENAME):
            backend.initialize_database()
        self.assertEqual((restored/'storage'/'first').read_bytes(), b'original')
        self.assertEqual(self.sql('SELECT id,stored_path,file_size_bytes,file_sha256 FROM documents', database=restored/backup.DATABASE_FILENAME), before)
        self.assertEqual(self.sql('SELECT COUNT(*) FROM document_upload_reservations_v1', database=restored/backup.DATABASE_FILENAME), [(0,)])

    def test_cli_exit_codes_and_value_free_output(self):
        self.make()
        script = Path(verifier.__file__)
        for expected in (0, 2, 1):
            if expected == 2:
                (self.artifact/'storage'/'extra').write_bytes(b'not referenced')
                self.refresh_manifest()
            if expected == 1:
                (self.artifact/'manifest.json').write_text('partial')
            result = subprocess.run([sys.executable, str(script), '--backup', str(self.artifact), '--source-storage', str(self.storage)], capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertEqual(result.stderr, '')
            self.assertNotIn(str(self.root), result.stdout)
            self.assertEqual(json.loads(result.stdout)['recoveryReady'], expected == 0)


if __name__ == '__main__':
    unittest.main()
