"""Local value-free upload storage metrics. No initialization, keys, network or writes.

This is a snapshot, not admission authorization. Run as the service OS user with
its explicit database/storage paths and the same upload policy environment.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys

TREE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TREE))
from Backend.document_upload_storage import Policy, NAMESPACE, TABLE, METADATA_BYTES, PRIVATE_DIRECTORY_MODES


def _regular(path):
    for parent in path.parents:
        if parent.is_symlink():
            raise ValueError('Unsafe path')
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise ValueError('Unsafe file')


def report(database, storage, policy=None):
    result = {'schema': 'upload-storage-health-v1', 'readOnly': True}
    descriptor = None
    try:
        policy = policy or Policy.from_environment()
        database, storage = Path(database).absolute(), Path(storage).absolute()
        _regular(database)
        for path in [storage, *storage.parents]:
            if path.is_symlink():
                raise ValueError('Unsafe storage path')
        if not storage.is_dir():
            raise ValueError('Storage missing')
        namespace = storage / NAMESPACE
        active = False
        namespace_identity = None
        if namespace.exists() or namespace.is_symlink():
            info = namespace.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) not in PRIVATE_DIRECTORY_MODES:
                raise ValueError('Unsafe namespace')
            namespace_identity = (info.st_dev, info.st_ino)
            lock = namespace / '.lock'
            _regular(lock)
            descriptor = os.open(lock, os.O_RDONLY | os.O_NOFOLLOW)
            info = os.fstat(descriptor)
            current = lock.lstat()
            if ((info.st_dev, info.st_ino) != (current.st_dev, current.st_ino)
                    or not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600):
                raise ValueError('Unsafe lock')
            try:
                fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                active = True
        connection = sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=0.2)
        try:
            connection.execute('PRAGMA query_only=ON')
            connection.set_progress_handler(lambda: 1, 100000)
            count, expected = connection.execute(f'SELECT COUNT(*),COALESCE(SUM(expected_bytes),0) FROM {TABLE}').fetchone()
        finally:
            connection.close()
        if descriptor is not None:
            current = lock.lstat()
            held = os.fstat(descriptor)
            directory = namespace.lstat()
            if ((current.st_dev, current.st_ino) != (held.st_dev, held.st_ino)
                    or (directory.st_dev, directory.st_ino) != namespace_identity):
                raise ValueError('Namespace changed')
        elif count:
            raise ValueError('Pending namespace missing')
        storage_stat, database_stat = os.statvfs(storage), os.statvfs(database.parent)
        free = storage_stat.f_bavail * storage_stat.f_frsize
        db_free = database_stat.f_bavail * database_stat.f_frsize
        separate = storage.stat().st_dev != database.parent.stat().st_dev
        # Charge all promised bytes conservatively; never inspect file contents.
        margin = free - policy.free_bytes - METADATA_BYTES - expected
        paused_path = database.parent / '.storage-rotation-paused'
        paused = paused_path.exists() or paused_path.is_symlink()
        pressure = count >= policy.pending_count or expected >= policy.pending_bytes or margin <= 0 or db_free <= policy.free_bytes + METADATA_BYTES or storage_stat.f_favail == 0 or database_stat.f_favail == 0
        result.update(status='paused' if paused else 'busy' if active else 'pressure' if pressure else 'ok',
                      globalMaintenancePaused=paused, uploadWriterActive=active,
                      snapshotStable=not active, storageFreeBytes=free, databaseFreeBytes=db_free,
                      separateDatabaseFilesystem=separate, storageFreeInodes=storage_stat.f_favail,
                      databaseFreeInodes=database_stat.f_favail, pendingCount=count,
                      pendingExpectedBytes=expected, pendingCountLimit=policy.pending_count,
                      pendingByteLimit=policy.pending_bytes, freeReserveBytes=policy.free_bytes,
                      conservativeFreeMarginBytes=margin, capacityPressure=pressure)
        return result
    except Exception:
        # No paths, actor IDs, filenames, SQL contents or exception strings.
        result.update(status='unavailable', errorCode='upload_metrics_unavailable')
        return result
    finally:
        if descriptor is not None:
            os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', type=Path, required=True)
    parser.add_argument('--storage', type=Path, required=True)
    args = parser.parse_args()
    result = report(args.database, args.storage)
    print(json.dumps(result, sort_keys=True))
    return 3 if result['status'] == 'unavailable' else 0 if result['status'] == 'ok' else 2


if __name__ == '__main__':
    raise SystemExit(main())
