import json
from pathlib import Path
import tempfile
import unittest
from cryptography.fernet import Fernet
from Tools.storage_rotation_custody import install_readers
from Backend.storage_keyring_file import load


class ReaderInstallationTests(unittest.TestCase):
    def test_private_reader_install_matches_live_keys_and_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            root.chmod(0o700)
            old = {domain: Fernet.generate_key().decode() for domain in ('qbo', 'google', 'push')}
            bundle = {'version': 1, 'readers': {domain: {'version': 1, 'active': 'old', 'write_format': 'legacy',
                'keys': {'old': value, 'new': Fernet.generate_key().decode()}} for domain, value in old.items()}}
            wrong = {**old, 'qbo': Fernet.generate_key().decode()}
            with self.assertRaises(ValueError): install_readers(root, 'keys', bundle, wrong)
            self.assertFalse((root / 'keys').exists())
            result = install_readers(root, 'keys', bundle, old)
            self.assertFalse(result['new_writes_activated'])
            path = root / 'keys' / 'readers.json'
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(set(load(str(path), old)), set(old))
            before = path.read_bytes()
            with self.assertRaises(ValueError): install_readers(root, 'keys', bundle, old)
            self.assertEqual(path.read_bytes(), before)
            bundle['readers']['qbo']['active'] = 'new'
            with self.assertRaises(ValueError): install_readers(root, 'activated', bundle, old)
            self.assertFalse((root / 'activated').exists())

if __name__ == '__main__': unittest.main()
