import json
import base64
import unittest
from cryptography.fernet import Fernet, InvalidToken
from Backend.storage_keyring import StorageKeyring, KeyringError

class StorageKeyringTests(unittest.TestCase):
    def setUp(self):
        self.old,self.new=Fernet.generate_key().decode(),Fernet.generate_key().decode()
    def ring(self,active='old',write_format='legacy',domain='qbo',retire=False):
        keys={'new':self.new} if retire else {'old':self.old,'new':self.new}
        return StorageKeyring(domain,self.old,json.dumps({'version':1,'active':active,'write_format':write_format,'keys':keys}))
    def test_binary_envelope_preserves_arbitrary_bytes_without_nested_base64(self):
        from Backend.storage_keyring import BINARY_PREFIX
        ring = self.ring('new', 'versioned')
        raw = bytes(range(256)) * 4096
        token = ring.encrypt(raw)
        inner = Fernet(self.new).decrypt(token)
        self.assertTrue(inner.startswith(BINARY_PREFIX))
        self.assertLess(len(inner) - len(raw), 1024)
        self.assertEqual(ring.decrypt(token), raw)
        for malformed in (BINARY_PREFIX, BINARY_PREFIX + (1025).to_bytes(4, 'big'),
                          BINARY_PREFIX + (50).to_bytes(4, 'big') + b'{}'):
            with self.assertRaises(InvalidToken):
                ring.decrypt(Fernet(self.new).encrypt(malformed))

    def test_prior_json_envelope_remains_readable_with_stable_revision(self):
        from Backend.storage_keyring import PREFIX
        value = {'v': 1, 'domain': 'qbo', 'key_id': 'old',
                 'revision': 'a' * 64, 'data': base64.b64encode(b'prior payload').decode()}
        token = Fernet(self.old).encrypt(PREFIX + json.dumps(value).encode())
        ring = self.ring('new', 'versioned')
        self.assertEqual(ring.decrypt(token), b'prior payload')
        migrated = ring.rotate(token)
        self.assertEqual(ring.revision(migrated), 'a' * 64)
        self.assertEqual(self.ring('new', 'versioned', retire=True).decrypt(migrated), b'prior payload')

    def test_reader_rollout_keeps_old_writes_and_reads_both_keys(self):
        ring=self.ring()
        self.assertEqual(Fernet(self.old).decrypt(ring.encrypt(b'value')),b'value')
        for key in (self.old,self.new):self.assertEqual(ring.decrypt(Fernet(key).encrypt(b'value')),b'value')
        with self.assertRaises(KeyringError):ring.rotate(Fernet(self.old).encrypt(b'value'))
    def test_rotation_preserves_revision_and_survives_old_key_retirement(self):
        before=Fernet(self.old).encrypt(b'recovery intent')
        old=self.ring();new=self.ring('new','versioned');rotated=new.rotate(before)
        self.assertEqual(old.decrypt(rotated),b'recovery intent')
        self.assertEqual(new.revision(rotated),old.revision(before))
        self.assertEqual(new.rotate(rotated),rotated)
        self.assertEqual(self.ring('new','versioned',retire=True).decrypt(rotated),b'recovery intent')
        with self.assertRaises(InvalidToken):Fernet(self.old).decrypt(rotated)
    def test_new_writes_need_dual_reader_rollback(self):
        token=self.ring('new','versioned').encrypt(b'new write')
        self.assertEqual(self.ring().decrypt(token),b'new write')
        with self.assertRaises(InvalidToken):StorageKeyring('qbo',self.old).decrypt(token)
    def test_domain_and_ciphertext_tampering_rejected(self):
        token=self.ring('new','versioned').encrypt(b'value')
        with self.assertRaises(InvalidToken):self.ring('new','versioned',domain='push').decrypt(token)
        for changed in (token[:-1]+b'!',token[:20]+b'!'+token[21:]):
            with self.assertRaises(InvalidToken):self.ring().decrypt(changed)
    def test_invalid_configuration_fails_closed_without_key_diagnostics(self):
        for config in ('bad',json.dumps({'keys':{'new':self.new}})):
            with self.assertRaises(KeyringError) as error:StorageKeyring('qbo',self.old,config)
            self.assertNotIn(self.old,str(error.exception));self.assertNotIn(self.new,str(error.exception))
        with self.assertRaises(KeyringError):self.ring('new','legacy')
    def test_versioned_tokens_preserve_public_cursor_base64_contract(self):
        token=self.ring('new','versioned').encrypt(b'cursor')
        self.assertEqual(base64.urlsafe_b64encode(base64.urlsafe_b64decode(token)),token)
    def test_fingerprint_overlap_and_retirement(self):
        data=b'mail\nsend\nsynthetic payload'
        before=self.ring().fingerprint(data)
        activated=self.ring('new','versioned')
        self.assertTrue(activated.accepts_fingerprint(data,before))
        after=activated.fingerprint(data)
        retired=self.ring('new','versioned',retire=True)
        self.assertTrue(retired.accepts_fingerprint(data,after))
        self.assertFalse(retired.accepts_fingerprint(data,before))
        self.assertFalse(activated.accepts_fingerprint(b'changed',before))
    def test_missing_old_key_does_not_rewrite_unreadable_token(self):
        token=Fernet(self.old).encrypt(b'value')
        with self.assertRaises(InvalidToken):self.ring('new','versioned',retire=True).rotate(token)
    def test_duplicate_configuration_and_reused_material_rejected(self):
        base={'version':1,'active':'old','write_format':'legacy','keys':{'old':self.old,'new':self.new}}
        for config in (json.dumps(base).replace('"version": 1','"version": 1,"version": 1'),
                       json.dumps({**base,'version':True}),
                       json.dumps({**base,'keys':{'old':self.old,'new':self.old}})):
            with self.assertRaises(KeyringError):StorageKeyring('qbo',self.old,config)
    def test_apns_accepts_valid_new_only_keyring_without_legacy_variable(self):
        from unittest import mock
        from Backend import gunnaire_backend as backend
        config=json.dumps({'version':1,'active':'new','write_format':'versioned','keys':{'new':self.new}})
        with mock.patch.multiple(backend,PUSH_TOKEN_ENCRYPTION_KEY='',PUSH_STORAGE_KEYRING=config,
                                 APNS_TEAM_ID='fixture',APNS_KEY_ID='fixture',APNS_PRIVATE_KEY_BASE64='fixture',APNS_TOPIC='fixture'):
            self.assertTrue(backend.apns_configuration_is_present())
            with mock.patch.object(backend,'PUSH_STORAGE_KEYRING','invalid'):
                self.assertFalse(backend.apns_configuration_is_present())
    def test_bad_staged_configuration_stops_before_database_or_workers(self):
        from unittest import mock
        from Backend import gunnaire_backend as backend
        for variable in ('QBO_STORAGE_KEYRING','GOOGLE_STORAGE_KEYRING','PUSH_STORAGE_KEYRING'):
            with mock.patch.object(backend,variable,'invalid'), mock.patch.object(backend,'AUTH_MODE','google-id-token'), \
                    mock.patch.object(backend,'initialize_database') as initialize, \
                    mock.patch.object(backend,'start_push_delivery_worker') as push, \
                    mock.patch.object(backend,'start_backup_worker') as backup:
                with self.assertRaises(SystemExit) as error:backend.main()
                self.assertEqual(str(error.exception),'Invalid staged storage keyring configuration')
                initialize.assert_not_called();push.assert_not_called();backup.assert_not_called()
    def test_allocation_slot_released_after_corruption_and_seal_failure(self):
        from unittest import mock
        from Backend.storage_keyring import ALLOCATION_SLOT
        ring=self.ring('new','versioned')
        with self.assertRaises(InvalidToken):ring.decrypt(b'corrupt')
        with mock.patch.object(ring,'_seal',side_effect=RuntimeError('synthetic failure')):
            with self.assertRaises(RuntimeError):ring.encrypt(b'value')
        self.assertTrue(ALLOCATION_SLOT.acquire(blocking=False))
        ALLOCATION_SLOT.release()
        self.assertEqual(ring.decrypt(ring.encrypt(b'recovered')),b'recovered')

if __name__=='__main__':unittest.main()
