"""Bounded rotation primitives for an OFFLINE, exclusively owned database copy.

Not a live migration command. A database transaction cannot fence an in-flight
provider call. Production use requires a separately verified stop/drain of all
writers and provider calls; this module deliberately supplies no live runner.
No plaintext, ciphertext or key material is included in diagnostics or results.
"""
import hashlib
import json
import re

INVENTORY = {'billing_assignment_mutations': ['payload_ciphertext'], 'billing_job_assignments': ['roster_ciphertext'], 'billing_publications': ['payload_ciphertext'], 'catalog_publications': ['payload_ciphertext'], 'cloudkit_staff_shares': ['participant_identity_ciphertext'], 'customer_publications': ['payload_ciphertext'], 'google_connections': ['secrets_ciphertext'], 'google_mail_operations': ['secrets_ciphertext', 'summary_ciphertext'], 'google_oauth_attempts': ['secrets_ciphertext'], 'push_devices': ['token_ciphertext'], 'qbo_capture_versions': ['payload_ciphertext'], 'qbo_connections': ['refresh_token_ciphertext'], 'qbo_document_upload_operations': ['payload_ciphertext'], 'qbo_document_uploads': ['payload_ciphertext', 'file_ciphertext', 'state_ciphertext'], 'qbo_link_reviews': ['payload_ciphertext'], 'staff_billing_projections': ['ciphertext'], 'staff_invoice_application_publications': ['ciphertext'], 'staff_invoice_line_requests': ['ciphertext'], 'staff_owner_field_edit_applications': ['ciphertext'], 'staff_owner_field_handoffs': ['ciphertext'], 'staff_owner_field_observations': ['ciphertext'], 'staff_owner_field_resolutions': ['ciphertext'], 'staff_owner_invoice_applications': ['ciphertext'], 'staff_replica_projections': ['ciphertext'], 'staff_replica_records': ['ciphertext'], 'staff_replica_transport_keys': ['ciphertext'], 'staff_workspace_cloud_seals': ['ciphertext'], 'staff_workspace_projections': ['ciphertext'], 'staff_workspace_selections': ['ciphertext'], 'staff_workspace_source_operations': ['ciphertext'], 'staff_workspace_source_records': ['ciphertext'], 'time_publications': ['payload_ciphertext', 'receipt_ciphertext'], 'time_worker_mapping_mutations': ['result_ciphertext'], 'time_worker_mappings': ['payload_ciphertext']}

class RotationError(ValueError):
    def __init__(self):
        super().__init__('Storage rotation validation failed; batch rolled back')

def domain_for(table):
    return 'google' if table.startswith('google_') else 'push' if table == 'push_devices' else 'qbo'

def canonical(value):
    return json.dumps(value, separators=(',', ':'), sort_keys=True)

def migrate_batch(connection, ring, table, column, *, after=0, max_rows=50, max_bytes=4*1024*1024):
    """Caller owns offline writer exclusion. Cursor is committed only on success.

    No progress table or business metadata is modified. Resume using returned
    cursor; rerunning any range is idempotent. NULL rows count toward row bounds.
    A final from-zero verification is required before retiring any reader key.
    """
    if (table not in INVENTORY or column not in INVENTORY[table]
            or domain_for(table) != ring.domain or not ring.versioned_writes
            or connection.in_transaction or type(after) is not int or after < 0
            or type(max_rows) is not int or not 1 <= max_rows <= 100
            or type(max_bytes) is not int or not 1 <= max_bytes <= 128*1024*1024):
        raise RotationError()
    cursor, changed, scanned, consumed = after, 0, 0, 0
    try:
        connection.execute('BEGIN IMMEDIATE')
        rows = connection.execute(f'SELECT rowid,length("{column}") FROM "{table}" WHERE rowid>? ORDER BY rowid LIMIT ?', (after,max_rows)).fetchall()
        for rowid, size in rows:
            if size is None:
                cursor, scanned = rowid, scanned+1
                continue
            if size > max_bytes:
                raise RotationError()
            if consumed + size > max_bytes:
                break
            source = connection.execute(f'SELECT * FROM "{table}" WHERE rowid=?',(rowid,)).fetchone()
            source = dict(source)
            token = source[column]
            if not isinstance(token,str):
                raise RotationError()
            if table == 'push_devices' and column == 'token_ciphertext' and token == '':
                # Only the explicit replaced-device tombstone is non-ciphertext.
                # An empty active/corrupt token must still stop retirement.
                prefix = 'replaced:' + source['id'] + ':'
                fingerprint = source['token_fingerprint']
                if (not source['deactivated_at'] or not isinstance(fingerprint,str)
                        or not fingerprint.startswith(prefix)
                        or not re.fullmatch('[0-9a-f]{64}',fingerprint[len(prefix):])):
                    raise RotationError()
                cursor, scanned = rowid, scanned+1
                continue
            original = token.encode('ascii')
            clear = ring.decrypt(original)
            rotated = ring.rotate(original).decode('ascii')
            updates = {column:rotated}
            if table == 'billing_job_assignments' and column == 'roster_ciphertext':
                before_hash = hashlib.sha256(canonical(token).encode()).hexdigest()
                if source['roster_hash'] != before_hash:
                    raise RotationError()
                updates['roster_hash'] = hashlib.sha256(canonical(rotated).encode()).hexdigest()
            if table == 'google_mail_operations' and column == 'secrets_ciphertext':
                payload = json.loads(clear)
                expected = {'v':1,'kind':'mail-operation','company':source['company_id'],
                            'owner':source['actor_email'],'id':source['id']}
                if (set(payload) != set(expected)|{'value'}
                        or any(payload[k] != v for k,v in expected.items())):
                    raise RotationError()
                proof = ('mail\n'+source['kind']+'\n'+canonical(payload['value'])).encode()
                if not ring.accepts_fingerprint(proof,source['fingerprint']):
                    raise RotationError()
                updates['fingerprint'] = ring.fingerprint(proof)
            if any(source[k] != v for k,v in updates.items()):
                fields = ','.join('"'+k+'"=?' for k in updates)
                count = connection.execute(f'UPDATE "{table}" SET {fields} WHERE rowid=? AND "{column}"=?', (*updates.values(),rowid,token)).rowcount
                if count != 1:
                    raise RotationError()
                changed += 1
            consumed += size
            cursor, scanned = rowid, scanned+1
        connection.commit()
        return {'cursor':cursor,'scanned':scanned,'changed':changed,'input_bytes':consumed}
    except Exception:
        connection.rollback()
        raise RotationError() from None
