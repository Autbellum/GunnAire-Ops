import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from cryptography.fernet import Fernet
from Backend.storage_keyring_file import load
from Backend.storage_keyring import StorageKeyring
from Backend import gunnaire_backend as backend


class ProtectedKeyringFileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.path = self.root / 'keyrings.json'
        self.old = {name: Fernet.generate_key().decode() for name in ('qbo', 'google', 'push')}
        self.bundle = {'version': 1, 'readers': {name: {
            'version': 1, 'active': 'old', 'write_format': 'legacy',
            'keys': {'old': value, 'new': Fernet.generate_key().decode()}}
            for name, value in self.old.items()}}
        self.write()

    def write(self):
        self.path.write_text(json.dumps(self.bundle))
        self.path.chmod(0o600)

    def test_reader_only_file_preserves_old_writes_and_all_domain_reads(self):
        result = load(str(self.path), self.old)
        for domain, setting in result.items():
            ring = StorageKeyring(domain, self.old[domain], setting)
            self.assertEqual(Fernet(self.old[domain]).decrypt(ring.encrypt(b'synthetic')), b'synthetic')
            new = self.bundle['readers'][domain]['keys']['new']
            self.assertEqual(ring.decrypt(Fernet(new).encrypt(b'mixed')), b'mixed')

    def test_insecure_permissions_symlinks_oversize_and_corruption_fail_closed(self):
        for mode in (0o644, 0o666):
            self.path.chmod(mode)
            with self.assertRaises(ValueError): load(str(self.path), self.old)
        self.path.chmod(0o600)
        self.root.chmod(0o755)
        with self.assertRaises(ValueError): load(str(self.path), self.old)
        self.root.chmod(0o700)
        alias = self.root / 'alias'
        alias.symlink_to(self.path)
        with self.assertRaises(ValueError): load(str(alias), self.old)
        folder = self.root / 'folder'
        folder.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError): load(str(folder / self.path.name), self.old)
        for value in ('x' * 16385, '{}', json.dumps(self.bundle).replace('"version": 1', '"version": 1,"version": 1', 1)):
            self.path.write_text(value)
            with self.assertRaises(ValueError) as error: load(str(self.path), self.old)
            self.assertEqual(str(error.exception), 'Protected storage keyring file is invalid or unavailable')

    def test_unavailable_explicit_file_stops_before_database_and_workers(self):
        with mock.patch.dict(os.environ, {'GUNNAIRE_STORAGE_KEYRING_FILE': str(self.root / 'missing')}, clear=True), \
                mock.patch.object(backend, 'AUTH_MODE', 'google-id-token'), \
                mock.patch.object(backend, 'initialize_database') as database, \
                mock.patch.object(backend, 'start_push_delivery_worker') as push, \
                mock.patch.object(backend, 'start_backup_worker') as backup:
            with self.assertRaises(SystemExit): backend.initialize_runtime()
            database.assert_not_called(); push.assert_not_called(); backup.assert_not_called()

    def test_startup_load_is_atomic_and_rejects_conflicting_sources(self):
        values = {'QBO_TOKEN_ENCRYPTION_KEY': self.old['qbo'], 'GOOGLE_TOKEN_ENCRYPTION_KEY': self.old['google'],
                  'PUSH_TOKEN_ENCRYPTION_KEY': self.old['push'], 'QBO_STORAGE_KEYRING': '',
                  'GOOGLE_STORAGE_KEYRING': '', 'PUSH_STORAGE_KEYRING': ''}
        with mock.patch.multiple(backend, **values), mock.patch.dict(os.environ,
                {'GUNNAIRE_STORAGE_KEYRING_FILE': str(self.path)}, clear=True):
            backend.load_protected_storage_keyrings()
            self.assertEqual(json.loads(backend.QBO_STORAGE_KEYRING), self.bundle['readers']['qbo'])
            before = (backend.QBO_STORAGE_KEYRING, backend.GOOGLE_STORAGE_KEYRING, backend.PUSH_STORAGE_KEYRING)
            self.bundle['readers']['push']['active'] = 'missing'
            self.write()
            with self.assertRaises(SystemExit): backend.load_protected_storage_keyrings()
            self.assertEqual((backend.QBO_STORAGE_KEYRING, backend.GOOGLE_STORAGE_KEYRING, backend.PUSH_STORAGE_KEYRING), before)
            with mock.patch.dict(os.environ, {'GUNNAIRE_QBO_STORAGE_KEYRING': 'conflicting'}):
                with self.assertRaisesRegex(SystemExit, 'Conflicting'): backend.load_protected_storage_keyrings()

    def test_absent_opt_in_retains_existing_environment_configuration(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(backend, 'QBO_STORAGE_KEYRING', 'unchanged'):
            backend.load_protected_storage_keyrings()
            self.assertEqual(backend.QBO_STORAGE_KEYRING, 'unchanged')

if __name__ == '__main__': unittest.main()
