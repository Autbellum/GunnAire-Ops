import json
import sqlite3
import unittest
from unittest import mock
from cryptography.fernet import Fernet
from Backend import gunnaire_backend as backend
from Backend.storage_keyring import StorageKeyring, ALLOCATION_SLOT
from Backend.storage_rotation import migrate_batch


class StorageAllocationTests(unittest.TestCase):
    def ring(self):
        old, new = Fernet.generate_key().decode(), Fernet.generate_key().decode()
        return StorageKeyring('qbo', old, json.dumps({'version': 1, 'active': 'new',
            'write_format': 'versioned', 'keys': {'old': old, 'new': new}}))

    def test_text_encoding_and_decoding_are_inside_admission(self):
        test = self
        def assert_held():
            acquired = ALLOCATION_SLOT.acquire(blocking=False)
            if acquired: ALLOCATION_SLOT.release()
            test.assertFalse(acquired)
        class CheckedText(str):
            def encode(self, *args, **kwargs):
                assert_held()
                return super().encode(*args, **kwargs)
        class CheckedBytes(bytes):
            def decode(self, *args, **kwargs):
                assert_held()
                return super().decode(*args, **kwargs)
        ring = self.ring()
        token = ring.encrypt_text(CheckedText('synthetic é'))
        self.assertEqual(ring.decrypt_text(CheckedText(token)), 'synthetic é')
        with mock.patch.object(ring, '_open', return_value=(CheckedBytes(b'clear'), 'a'*64, 'new', True)):
            self.assertEqual(ring.decrypt_text(CheckedText(token)), 'clear')
        with mock.patch.object(ring, '_seal', return_value=CheckedBytes(b'cipher')):
            self.assertEqual(ring.encrypt_text(CheckedText('clear')), 'cipher')
        with self.assertRaises(UnicodeError): ring.encrypt_text('é', 'ascii')
        self.assertTrue(ALLOCATION_SLOT.acquire(blocking=False)); ALLOCATION_SLOT.release()

    def test_ordinary_migration_does_not_retain_separate_plaintext(self):
        ring = self.ring()
        with sqlite3.connect(':memory:') as connection:
            connection.row_factory = sqlite3.Row
            connection.execute('CREATE TABLE time_publications(payload_ciphertext TEXT)')
            connection.execute('INSERT INTO time_publications VALUES (?)', (ring.keys['old'].encrypt(b'synthetic').decode(),))
            connection.commit()
            with mock.patch.object(ring, 'decrypt', side_effect=AssertionError('Duplicate plaintext')), \
                    mock.patch.object(ring, 'decrypt_text', side_effect=AssertionError('Duplicate plaintext')):
                self.assertEqual(migrate_batch(connection, ring, 'time_publications', 'payload_ciphertext')['changed'], 1)
            self.assertEqual(ring.decrypt_text(connection.execute('SELECT payload_ciphertext FROM time_publications').fetchone()[0]), 'synthetic')

    def test_workspace_admission_precedes_body_and_releases_on_errors(self):
        handler = object.__new__(backend.GunnAireBackendHandler)
        handler._handle_staff_workspace_source = mock.Mock()
        handler.write_json = mock.Mock()
        with backend.WORKSPACE_SOURCE_SLOTS:
            handler.handle_staff_workspace_source(None, method='POST')
        handler._handle_staff_workspace_source.assert_not_called()
        self.assertEqual(handler.write_json.call_args.kwargs['status'], 503)
        def operation(*args, **kwargs):
            acquired = backend.WORKSPACE_SOURCE_SLOTS.acquire(blocking=False)
            if acquired: backend.WORKSPACE_SOURCE_SLOTS.release()
            self.assertFalse(acquired)
            raise RuntimeError('Synthetic response failure')
        handler._handle_staff_workspace_source.side_effect = operation
        with self.assertRaises(RuntimeError): handler.handle_staff_workspace_source(None, method='POST')
        self.assertTrue(backend.WORKSPACE_SOURCE_SLOTS.acquire(blocking=False)); backend.WORKSPACE_SOURCE_SLOTS.release()
        handler._handle_staff_workspace_source.side_effect = None
        with backend.WORKSPACE_SOURCE_SLOTS:
            handler.handle_staff_workspace_source(None, method='GET')
        handler._handle_staff_workspace_source.assert_called_with(None, method='GET')

if __name__ == '__main__': unittest.main()
