"""Fail-closed verdicts for synthetic entrypoint validation."""
import base64
import hashlib
import uuid
from Tools.quota_runtime import MEMORY_MAX, HEADROOM_MAX


def upload_readback_targets(rows):
    """Validate every successful creation before building any readback URL."""
    identifiers = []
    for row in rows:
        if row['kind'] != 'upload' or row.get('status') != 201:
            continue
        body = row.get('json')
        value = body.get('id') if isinstance(body, dict) else None
        if not isinstance(value, str):
            raise ValueError('Successful upload has no valid document identity')
        try:
            canonical = str(uuid.UUID(value))
        except ValueError:
            raise ValueError('Successful upload has no valid document identity') from None
        if canonical != value or value in identifiers:
            raise ValueError('Successful uploads must have distinct canonical document identities')
        identifiers.append(value)
    return identifiers


def verdict(rows, retries, readbacks, health, samples, backups, waves,
            download_digest, upload_digest, replica_digest, survived, sample_errors):
    downloads = [r for r in rows if r['kind'] == 'download']
    uploads = [r for r in rows if r['kind'] == 'upload']
    replicas = [r for r in rows if r['kind'] == 'replica']
    metadata = [r for r in rows if r['kind'] == 'metadata']
    successful_uploads = [r for r in uploads if r.get('status') == 201]
    try:
        upload_ids = upload_readback_targets(rows)
        identities_match = [r.get('documentID') for r in readbacks] == upload_ids
    except ValueError:
        identities_match = False
    rejected_downloads = [r for r in downloads if r.get('status') == 503]
    def exact(r, size, digest):
        return r.get('status') == 200 and r.get('bytes') == size and r.get('sha256') == digest
    def valid_replica(r):
        try:
            body = r['json']
            raw = base64.b64decode(body['payloadBase64'], validate=True)
            return (r['status'] == 200 and bool(raw)
                    and hashlib.sha256(raw).hexdigest() == body['chunkSHA256'] == replica_digest)
        except (KeyError, ValueError, TypeError):
            return False
    peak = max((r['peak'] for r in samples), default=0)
    events_ok = all(not any(r['events'].get(k, 0) for k in ['oom', 'oom_kill', 'oom_group_kill'])
                    for r in samples)
    return {
        'completeWorkload': (len(downloads) == 8 * waves and len(uploads) == 8 * waves
                             and len(replicas) == 4 * waves and len(metadata) == 4 * waves),
        'serverSurvived': survived,
        'measurementValid': bool(samples) and not sample_errors and events_ok,
        'underBudget': bool(samples) and peak < MEMORY_MAX,
        'met20PercentHeadroom': bool(samples) and peak < HEADROOM_MAX,
        'allHealthUnder5Seconds': bool(health) and all(r.get('status') == 200 and r['seconds'] < 5 for r in health),
        'metadataRejected': bool(metadata) and all(r.get('status') == 400 for r in metadata),
        'downloadsVerified': (any(r.get('status') == 200 for r in downloads)
            and all(r.get('status') in (200, 503) for r in downloads)
            and all(exact(r, 64 * 1024**2, download_digest) for r in downloads if r.get('status') == 200)
            and len(retries) == len(rejected_downloads)
            and all(exact(r, 64 * 1024**2, download_digest) for r in retries)),
        'uploadsVerified': (bool(successful_uploads) and identities_match and len(readbacks) == len(successful_uploads)
            and all(exact(r, 12 * 1024**2, upload_digest) for r in readbacks)
            and all(r.get('status') in (201, 503) or r.get('error') in
                    ('BrokenPipeError', 'ConnectionResetError', 'RemoteDisconnected') for r in uploads)),
        'replicasVerified': bool(replicas) and all(valid_replica(r) for r in replicas),
        'backupVerified': bool(backups),
    }
