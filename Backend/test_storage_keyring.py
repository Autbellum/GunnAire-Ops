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

if __name__=='__main__':unittest.main()
