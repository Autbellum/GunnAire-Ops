import json
import sqlite3
import unittest
from unittest import mock
from cryptography.fernet import Fernet
from Backend.storage_keyring import StorageKeyring
from Backend.storage_rotation import migrate_batch, RotationError
from Backend import gunnaire_backend as backend


class StorageRotationTests(unittest.TestCase):
    def setUp(self):
        self.old, self.new = Fernet.generate_key().decode(), Fernet.generate_key().decode()
        self.config = {'version':1,'active':'new','write_format':'versioned','keys':{'old':self.old,'new':self.new}}
        self.ring = StorageKeyring('qbo',self.old,json.dumps(self.config))
        self.db = sqlite3.connect(':memory:')
        self.db.row_factory = sqlite3.Row
        self.addCleanup(self.db.close)
        self.db.execute('CREATE TABLE time_publications (payload_ciphertext TEXT, receipt_ciphertext TEXT, state TEXT)')

    def seed(self, values):
        self.db.executemany('INSERT INTO time_publications VALUES (?,NULL,?)',
                            [(Fernet(self.old).encrypt(v).decode(), 'uncertain') for v in values])
        self.db.commit()

    def test_bounded_resume_exact_plaintext_history_nulls_and_idempotence(self):
        originals = [b'historical',b'pending',b'\x00cloud key and nonce\xff']
        self.seed(originals)
        first = migrate_batch(self.db,self.ring,'time_publications','payload_ciphertext',max_rows=1)
        self.assertEqual((first['changed'],first['cursor']),(1,1))
        second = migrate_batch(self.db,self.ring,'time_publications','payload_ciphertext',after=first['cursor'])
        self.assertEqual(second['changed'],2)
        self.assertEqual(migrate_batch(self.db,self.ring,'time_publications','payload_ciphertext')['changed'],0)
        retired = StorageKeyring('qbo',self.new,json.dumps({**self.config,'keys':{'new':self.new}}))
        rows = self.db.execute('SELECT * FROM time_publications').fetchall()
        self.assertEqual([retired.decrypt(r['payload_ciphertext'].encode()) for r in rows], originals)
        self.assertTrue(all(r['receipt_ciphertext'] is None and r['state']=='uncertain' for r in rows))
        self.assertEqual(migrate_batch(self.db,self.ring,'time_publications','receipt_ciphertext')['changed'],0)

    def test_corrupt_cell_rolls_back_entire_batch(self):
        self.seed([b'one',b'two'])
        self.db.execute("UPDATE time_publications SET payload_ciphertext='corrupt' WHERE rowid=2")
        self.db.commit()
        before = list(map(tuple,self.db.execute('SELECT * FROM time_publications')))
        with self.assertRaises(RotationError):
            migrate_batch(self.db,self.ring,'time_publications','payload_ciphertext')
        self.assertEqual(list(map(tuple,self.db.execute('SELECT * FROM time_publications'))),before)

    def test_byte_bound_and_unknown_schema_fail_without_changes(self):
        self.seed([b'large enough'])
        for table,column,kwargs in [('time_publications','payload_ciphertext',{'max_bytes':1}),
                                    ('unknown','ciphertext',{}),('time_publications','state',{})]:
            with self.assertRaises(RotationError):migrate_batch(self.db,self.ring,table,column,**kwargs)
        self.assertFalse(self.ring.uses_active_envelope(self.db.execute('SELECT payload_ciphertext FROM time_publications').fetchone()[0].encode()))

    def test_roster_hash_updated_atomically_integer_revision_preserved(self):
        from Backend.billing_assignments import digest
        self.db.execute('CREATE TABLE billing_job_assignments(roster_ciphertext TEXT,roster_hash TEXT,revision INTEGER)')
        token=Fernet(self.old).encrypt(b'roster').decode()
        self.db.execute('INSERT INTO billing_job_assignments VALUES (?,?,17)',(token,digest(token)))
        self.db.commit()
        migrate_batch(self.db,self.ring,'billing_job_assignments','roster_ciphertext')
        row=self.db.execute('SELECT * FROM billing_job_assignments').fetchone()
        self.assertEqual(row['roster_hash'],digest(row['roster_ciphertext']))
        self.assertEqual(row['revision'],17)

    def test_upload_original_revision_survives_rotation_and_no_duplicate_send(self):
        from Backend.test_qbo_document_uploads import DocumentUploadTests
        fixture=DocumentUploadTests();fixture.setUp();self.addCleanup(fixture.tearDown)
        fixture.service.ciphertext_revision=backend.qbo_ciphertext_revision
        old=backend.QBO_TOKEN_ENCRYPTION_KEY
        record=fixture.reserve()
        config={**self.config,'keys':{'old':old,'new':self.new}}
        ring=StorageKeyring('qbo',old,json.dumps(config))
        with backend.db() as connection:
            for column in ('payload_ciphertext','file_ciphertext','state_ciphertext'):
                migrate_batch(connection,ring,'qbo_document_uploads',column)
        with mock.patch.object(backend,'QBO_STORAGE_KEYRING',json.dumps({**config,'keys':{'new':self.new}})):
            first=fixture.send(record)
            replay=fixture.send(record)
            self.assertEqual(first,replay)
            self.assertEqual(len(fixture.sent),1)

    def test_google_mail_retry_after_migration_retains_receipt_without_post(self):
        from Backend.test_google_mail import GoogleMailTests
        fixture=GoogleMailTests();fixture.setUp();self.addCleanup(fixture.doCleanups)
        first=fixture.prepare()
        google=fixture.fixture.service
        config={**self.config,'keys':{'old':google.encryption_key,'new':self.new}}
        ring=StorageKeyring('google',google.encryption_key,json.dumps(config))
        with google.database() as connection:
            for table,columns in [('google_connections',['secrets_ciphertext']),
                                  ('google_mail_operations',['secrets_ciphertext','summary_ciphertext'])]:
                for column in columns:migrate_batch(connection,ring,table,column)
        google.keyring_configuration=json.dumps({**config,'keys':{'new':self.new}})
        self.assertEqual(fixture.prepare(),first)
        self.assertEqual(fixture.post_count(),0)

    def test_link_approval_original_revision_survives_rotation(self):
        from Backend.test_qbo_link_adoption import LinkAdoptionTests
        fixture=LinkAdoptionTests();fixture.setUp();self.addCleanup(fixture.tearDown)
        fixture.adopter.ciphertext_revision=backend.qbo_ciphertext_revision
        review=fixture.preview()
        old=backend.QBO_TOKEN_ENCRYPTION_KEY
        config={**self.config,'keys':{'old':old,'new':self.new}}
        ring=StorageKeyring('qbo',old,json.dumps(config))
        with backend.db() as connection:migrate_batch(connection,ring,'qbo_link_reviews','payload_ciphertext')
        with mock.patch.object(backend,'QBO_STORAGE_KEYRING',json.dumps({**config,'keys':{'new':self.new}})):
            result=fixture.confirm(review)
            reads=len(fixture.reads)
            self.assertEqual(fixture.confirm(review),result)
            self.assertEqual(len(fixture.reads),reads)
            self.assertEqual(fixture.writes,[])

    def test_cloudkit_original_key_nonce_aad_and_sealed_bytes_survive_rotation(self):
        from Backend.test_staff_replica_transport import StaffReplicaTransportTests
        original_encrypt,original_decrypt=backend.encrypt_catalog_payload,backend.decrypt_catalog_payload
        fixture=StaffReplicaTransportTests()
        with mock.patch('Backend.test_cloudkit_staff_shares.Fernet', wraps=Fernet) as factory:
            factory.generate_key.return_value=self.old.encode()
            fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        before=fixture.read()
        self.assertEqual(before[0],200)
        old=self.old
        config={**self.config,'keys':{'old':old,'new':self.new}}
        ring=StorageKeyring('qbo',old,json.dumps(config))
        with backend.db() as connection:
            for table,column in [('cloudkit_staff_shares','participant_identity_ciphertext'),
                                 ('staff_replica_records','ciphertext'),('staff_replica_projections','ciphertext'),
                                 ('staff_replica_transport_keys','ciphertext')]:
                migrate_batch(connection,ring,table,column)
        with mock.patch.multiple(backend, QBO_STORAGE_KEYRING=json.dumps({**config,'keys':{'new':self.new}}),
                                 encrypt_catalog_payload=original_encrypt,decrypt_catalog_payload=original_decrypt):
            self.assertEqual(fixture.read(),before)

    def test_old_mail_cursor_works_during_overlap_and_requires_refresh_after_retirement(self):
        import uuid
        from Backend.test_google_mail import GoogleMailTests
        fixture=GoogleMailTests();fixture.setUp();self.addCleanup(fixture.doCleanups)
        google=fixture.fixture.service
        context=fixture.context()
        token=google.seal('mail-cursor',context.company,context.owner,context.grant,
                          {'createdAt':google.now().isoformat(),'id':str(uuid.uuid4())})
        config={**self.config,'keys':{'old':google.encryption_key,'new':self.new}}
        ring=StorageKeyring('google',google.encryption_key,json.dumps(config))
        with google.database() as connection:migrate_batch(connection,ring,'google_connections','secrets_ciphertext')
        google.keyring_configuration=json.dumps(config)
        fixture.service.outbox(context,before=token)
        google.keyring_configuration=json.dumps({**config,'keys':{'new':self.new}})
        fixture.assert_code('mail_changed',lambda:fixture.service.outbox(context,before=token))
        self.assertEqual(fixture.post_count(),0)

if __name__=='__main__':unittest.main()
