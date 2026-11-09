#!/usr/bin/env python3
"""Offline cross-resource verification; never repairs/adopts input or decrypts data.

Exit 0: all committed references proven, no unexplained files or pending state.
Exit 2: manifest copy valid, but historical proof/extras/pending need review.
Exit 1: invalid, changing, unsafe, incomplete, or over-budget artifact.
This certifies a captured snapshot, not freshness, deployment or a restore action.
"""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path, PurePosixPath
import sqlite3
import stat
import tempfile

try:
    from . import backup_backend
except ImportError:
    import backup_backend


class Invalid(Exception):
    pass


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def open_directory(path):
    """Pin every component, including ancestors; do not resolve symlinks."""
    path = Path(path).absolute()
    if '..' in path.parts:
        raise Invalid()
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def capture(fd, destination, budget, depth=0):
    """Bounded private working copy, pinned inputs, reject changes during capture."""
    if depth > 64:
        raise Invalid()
    before = identity(os.fstat(fd))
    names = []
    with os.scandir(fd) as entries:
        for entry in entries:
            if len(names) >= budget[0]:
                raise Invalid()
            names.append(entry.name)
    names.sort()
    for name in names:
        budget[0] -= 1
        if budget[0] < 0:
            raise Invalid()
        original = os.stat(name, dir_fd=fd, follow_symlinks=False)
        if stat.S_ISDIR(original.st_mode):
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            try:
                if identity(original) != identity(os.fstat(child)):
                    raise Invalid()
                target = destination / name
                target.mkdir(mode=0o700)
                capture(child, target, budget, depth + 1)
            finally:
                os.close(child)
        elif stat.S_ISREG(original.st_mode) and original.st_nlink == 1:
            budget[1] -= original.st_size
            if budget[1] < 0 or (name == 'manifest.json' and original.st_size > 10*1024*1024):
                raise Invalid()
            source = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            try:
                if identity(original) != identity(os.fstat(source)):
                    raise Invalid()
                with (destination / name).open('xb') as outgoing:
                    remaining = original.st_size
                    while remaining:
                        chunk = os.read(source, min(1024*1024, remaining))
                        if not chunk:
                            raise Invalid()
                        outgoing.write(chunk)
                        remaining -= len(chunk)
                    if os.read(source, 1) or identity(original) != identity(os.fstat(source)):
                        raise Invalid()
            finally:
                os.close(source)
        else:
            raise Invalid()
        if identity(original) != identity(os.stat(name, dir_fd=fd, follow_symlinks=False)):
            raise Invalid()
    if before != identity(os.fstat(fd)) or names != sorted(os.listdir(fd)):
        raise Invalid()


def relative_document(value, source_root):
    if not isinstance(value, str) or '\\' in value or '\x00' in value:
        raise Invalid()
    path = PurePosixPath(value)
    if not path.is_absolute() or '..' in path.parts or str(path) != value:
        raise Invalid()
    try:
        relative = path.relative_to(source_root)
    except ValueError:
        raise Invalid() from None
    if not relative.parts:
        raise Invalid()
    return 'storage/' + relative.as_posix()


def reconcile(root, source_root, report):
    if {p.name for p in root.iterdir()} != {'storage', 'manifest.json', 'gunnaire_backend.sqlite3'}:
        raise Invalid()
    manifest = json.loads((root / 'manifest.json').read_text())
    if not isinstance(manifest, dict) or not isinstance(manifest.get('database'), dict):
        raise Invalid()
    if manifest['database'].get('path') != 'gunnaire_backend.sqlite3':
        raise Invalid()
    records = manifest.get('documents')
    if not isinstance(records, list):
        raise Invalid()
    for record in records:
        value = record.get('path') if isinstance(record, dict) else None
        if (not isinstance(value, str) or not value.startswith('storage/')
                or '..' in PurePosixPath(value).parts or str(PurePosixPath(value)) != value):
            raise Invalid()
    backup_backend.verify_backup(root)
    report['byteCopyConsistent'] = True
    files = {p.relative_to(root).as_posix(): p for p in (root / 'storage').rglob('*') if p.is_file()}
    referenced = set()
    database = root / 'gunnaire_backend.sqlite3'
    with closing(sqlite3.connect(database.as_uri() + '?mode=ro&immutable=1', uri=True)) as connection:
        connection.execute('PRAGMA query_only=ON')
        connection.execute('PRAGMA trusted_schema=OFF')
        connection.set_progress_handler(lambda: 1, 10_000_000)
        definitions = list(connection.execute('SELECT name,type,sql FROM sqlite_master'))
        if any('CREATE VIRTUAL TABLE' in (row[2] or '').upper() for row in definitions):
            raise Invalid()
        tables = {row[0]: row[1] for row in definitions}
        if tables.get('documents') != 'table':
            raise Invalid()
        for stored, size, digest in connection.execute('SELECT stored_path,file_size_bytes,file_sha256 FROM documents'):
            relative = relative_document(stored, source_root)
            if relative in referenced or relative not in files:
                raise Invalid()
            referenced.add(relative)
            report['committedDocuments'] += 1
            if size is None and digest is None:
                report['historicalUnverifiedDocuments'] += 1
                continue
            if (type(size) is not int or size < 0 or not isinstance(digest, str)
                    or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest)):
                raise Invalid()
            file = files[relative]
            if file.stat().st_size != size or backup_backend.sha256_file(file) != digest:
                raise Invalid()
            report['provenDocuments'] += 1
        pending = 'document_upload_reservations_v1'
        if pending in tables:
            if tables[pending] != 'table':
                raise Invalid()
            report['pendingReservations'] = connection.execute('SELECT COUNT(*) FROM document_upload_reservations_v1').fetchone()[0]
        extras = set(files) - referenced
        # Only the known empty lock is infrastructure; payloads are never adopted.
        lock = 'storage/.document-upload-v1/.lock'
        if lock in extras and files[lock].stat().st_size == 0:
            extras.remove(lock)
            report['infrastructureFiles'] = 1
        report['unreferencedFiles'] = len(extras)


def verify(artifact, source_storage, *, max_bytes=1024**3, max_entries=10000):
    report = dict(schema='cross-resource-recovery-v1', status='invalid', recoveryReady=False,
                  byteCopyConsistent=False, committedDocuments=0, provenDocuments=0,
                  historicalUnverifiedDocuments=0, pendingReservations=0,
                  unreferencedFiles=0, infrastructureFiles=0,
                  scope='captured-offline-snapshot', originalIntegrityProven=False)
    try:
        source_root = PurePosixPath(source_storage)
        if (not source_root.is_absolute() or '..' in source_root.parts
                or str(source_root) != str(source_storage) or source_root == PurePosixPath('/')):
            raise Invalid()
        with tempfile.TemporaryDirectory(prefix='gunnaire-snapshot-verify-') as temporary:
            root = Path(temporary)
            fd = open_directory(artifact)
            try:
                capture(fd, root, [max_entries, max_bytes])
            finally:
                os.close(fd)
            reconcile(root, source_root, report)
        reasons = [reason for key, reason in (
            ('historicalUnverifiedDocuments', 'historical_proof_missing'),
            ('pendingReservations', 'pending_ownership_not_portable'),
            ('unreferencedFiles', 'unreferenced_files_require_review')) if report[key]]
        review = bool(reasons)
        report.update(status='review_required' if review else 'verified', recoveryReady=not review,
                      originalIntegrityProven=not report['historicalUnverifiedDocuments'], reviewReasons=reasons)
        return report, 2 if review else 0
    except Exception:
        # Malformed/deep inputs and unexpected verification failures must never
        # leak paths/records in a traceback or turn a partial check into success.
        report['errorCode'] = 'snapshot_not_certified'
        return report, 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backup', required=True)
    parser.add_argument('--source-storage', required=True, help='Original absolute storage path; mapping only, never read')
    args = parser.parse_args()
    report, code = verify(args.backup, args.source_storage)
    print(json.dumps(report, sort_keys=True))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
