"""Fail-closed verdicts for bounded synthetic upload recovery evidence."""
import hashlib
import uuid
from Tools.quota_runtime import MEMORY_MAX, HEADROOM_MAX


def resource_checks(samples, errors=(), alive=True):
    valid = bool(samples) and not errors and all(
        type(s.get('peak')) is int and s['peak'] >= 0
        and not any(s.get('events', {}).get(k, 0) for k in ('oom', 'oom_kill', 'oom_group_kill'))
        for s in samples)
    peak = max((s.get('peak', MEMORY_MAX) for s in samples), default=MEMORY_MAX)
    return dict(measurementValid=valid, belowMemoryBudget=peak < MEMORY_MAX,
                belowHeadroomTarget=peak < HEADROOM_MAX, serverAlive=alive)


def verdict(rows, samples, errors, identifier, digest, size, alive, final=None):
    checks = resource_checks(samples, errors, alive)
    try:
        identity_valid = str(uuid.UUID(identifier)) == identifier
    except (TypeError, ValueError, AttributeError):
        identity_valid = False
    checks['completeWorkload'] = len(rows) == 72 and all(
        sum(r.get('wave') == wave and r.get('kind') == kind for r in rows) == 8
        for wave in range(3) for kind in ('recovery', 'replay', 'download'))
    checks['expectedFixture'] = identity_valid and size == 25*1024**2 and digest == hashlib.sha256(b'm'*size).hexdigest()
    checks['boundedOutcomes'] = all(
        r.get('status') in ((201,503) if r.get('kind') == 'replay' else (200,503))
        or (r.get('kind') == 'replay' and r.get('error') in ('BrokenPipeError','ConnectionResetError','RemoteDisconnected'))
        for r in rows)
    checks['exactSuccesses'] = all(
        (r.get('json',{}).get('id') == identifier if r.get('kind') == 'replay' else
         r.get('json',{}).get('document',{}).get('id') == identifier and
         r.get('json',{}).get('document',{}).get('fileSHA256') == digest if r.get('kind') == 'recovery' else
         r.get('bytes') == size and r.get('sha256') == digest)
        for r in rows if r.get('status') in (200,201))
    final = final or {}
    checks['verifiedFinalReadbacks'] = (final.get('recovery') == identifier and final.get('recoveryHash') == digest and final.get('replay') == identifier and final.get('downloadHash') == digest and final.get('downloadBytes') == size and final.get('committed') == 1 and final.get('pending') == 0 and final.get('actorStatus') == 409 and final.get('healthStatuses') == [200]*3)
    return checks


def crash_verdict(samples, completion, code):
    checks = resource_checks(samples, alive=code == 0)
    attempts = completion.get('crashAttempts', [])
    size = 12*1024**2
    checks['fourDurableCrashes'] = len(attempts) == 4 and all(
        r.get('failedAttempts') == i+1 and r.get('committedRows') == 0 and
        r.get('pendingRows') == 1 and r.get('payloadFiles') == 1 and
        r.get('logicalBytes') == size and r.get('sameInode') is True
        for i,r in enumerate(attempts))
    end = (completion.get('afterRetry') or {})
    checks['oneRecoveryNoOrphan'] = (completion.get('payloadBytes') == size and
        end.get('committedRows') == 1 and end.get('pendingRows') == 0 and
        end.get('payloadFiles') == 1 and end.get('logicalBytes') == size and
        end.get('sha256') == hashlib.sha256(b'o'*size).hexdigest())
    checks['pendingCapacityRecovery'] = completion.get('distinctCrashBudget') == {
        'pendingByteCap':24*1024**2,'blockedThirdStatus':503,'pendingAtCap':2,
        'payloadFilesAtCap':2,'existingRecoveryStatus':201,'pendingAfterRecovery':1,'committedAfterRecovery':1}
    return checks
