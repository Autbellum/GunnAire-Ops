#!/usr/bin/env python3
"""Generate a standalone checkpoint from a stable, authoritative WAL source bundle.

Only the new private destination is written. Source SQLite is never opened by
SQLite (even read-only SQLite can coordinate through source SHM). Exit codes
match verify_recovery_snapshot. Missing WAL frames are never silently accepted.
"""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import struct

try:
    from . import backup_backend as backup, verify_recovery_snapshot as verifier
except ImportError:
    import backup_backend as backup
    import verify_recovery_snapshot as verifier

DB = backup.DATABASE_FILENAME
MAX_BYTES = 1024**3


def inventory(fd, result=None, prefix='', depth=0):
    """Bounded metadata fence across the WHOLE capture, including earlier files."""
    if result is None:
        result = {}
    if depth > 64:
        raise verifier.Invalid()
    result[prefix] = verifier.identity(os.fstat(fd))
    with os.scandir(fd) as entries:
        for entry in entries:
            if len(result) >= 10000:
                raise verifier.Invalid()
            info = os.stat(entry.name, dir_fd=fd, follow_symlinks=False)
            key = prefix + '/' + entry.name
            result[key] = verifier.identity(info)
            if stat.S_ISDIR(info.st_mode):
                child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    if verifier.identity(os.fstat(child)) != verifier.identity(info):
                        raise verifier.Invalid()
                    inventory(child, result, key, depth + 1)
                finally:
                    os.close(child)
            elif not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise verifier.Invalid()
    return result


def wal_frames(path):
    """Shape/commit boundary only; SQLite validates actual salts/checksums below.

    Format: https://www.sqlite.org/fileformat2.html#walformat
    """
    size = path.stat().st_size
    with path.open('rb') as stream:
        header = stream.read(32)
        if len(header) != 32:
            raise verifier.Invalid()
        magic, version, page_size = struct.unpack('>III', header[:12])
        if magic not in (0x377f0682, 0x377f0683) or version != 3007000:
            raise verifier.Invalid()
        if page_size < 512 or page_size > 65536 or page_size & (page_size-1):
            raise verifier.Invalid()
        frames, remainder = divmod(size - 32, page_size + 24)
        if frames < 1 or remainder:
            raise verifier.Invalid()
        stream.seek(32 + (frames-1)*(page_size+24))
        page, committed_size = struct.unpack('>II', stream.read(8))
        if not page or not committed_size or committed_size * page_size > MAX_BYTES:
            raise verifier.Invalid()
    return frames


def standalone(capture, output):
    database = capture / DB
    with database.open('rb') as stream:
        if stream.read(20)[18:20] != b'\x02\x02':
            raise verifier.Invalid()
    expected = wal_frames(capture / (DB+'-wal'))
    # Ignore captured SHM and rebuild coordination ONLY in our private copy.
    (capture / (DB+'-shm')).unlink(missing_ok=True)
    with closing(sqlite3.connect(database)) as source:
        source.execute('PRAGMA trusted_schema=OFF')
        source.execute('PRAGMA busy_timeout=1000')
        observed = source.execute('PRAGMA wal_checkpoint(PASSIVE)').fetchone()
        if observed != (0, expected, expected):
            raise verifier.Invalid()
        with closing(sqlite3.connect(output)) as destination:
            source.backup(destination, pages=256, sleep=0.01)
            if destination.execute('PRAGMA journal_mode=DELETE').fetchone() != ('delete',):
                raise verifier.Invalid()
    with output.open('rb') as stream:
        if stream.read(20)[18:20] != b'\x01\x01':
            raise verifier.Invalid()
        os.fsync(stream.fileno())
    if any(Path(str(output)+suffix).exists() for suffix in ('-wal', '-shm', '-journal')):
        raise verifier.Invalid()
    return expected


def durable_json(path, payload):
    backup.write_json_atomic(path, payload)
    with path.open('rb') as stream:
        os.fsync(stream.fileno())
    fd = verifier.open_directory(path.parent)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def generate(source_bundle, source_storage, destination):
    report = dict(schema='wal-checkpoint-v1', status='invalid', recoveryReady=False,
                  sourceStableDuringCapture=False, capturedWalFrames=0)
    fd = parent = None
    try:
        source_bundle, destination = Path(source_bundle).absolute(), Path(destination).absolute()
        if destination == source_bundle or source_bundle in destination.parents:
            raise verifier.Invalid()
        fd = verifier.open_directory(source_bundle)
        names = set(os.listdir(fd))
        if not {DB, DB+'-wal', 'storage'} <= names or names - {DB, DB+'-wal', DB+'-shm', 'storage'}:
            raise verifier.Invalid()
        parent = verifier.open_directory(destination.parent)
        info = os.fstat(parent)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o022:
            raise verifier.Invalid()
        os.mkdir(destination.name, 0o700, dir_fd=parent)  # Never overwrite/reuse.
        if verifier.identity(os.stat(destination.parent)) != verifier.identity(os.fstat(parent)):
            raise verifier.Invalid()
        captured = destination / 'capture'
        captured.mkdir(mode=0o700)
        before = inventory(fd)
        verifier.capture(fd, captured, [10000, MAX_BYTES])
        if inventory(fd) != before:
            raise verifier.Invalid()
        report['sourceStableDuringCapture'] = True
        artifact = destination / 'artifact'
        artifact.mkdir(mode=0o700)
        report['capturedWalFrames'] = standalone(captured, artifact / DB)
        shutil.copytree(captured/'storage', artifact/'storage',
                        copy_function=lambda src, dst: backup.copy_document(Path(src), Path(dst)))
        for directory in sorted((p for p in (artifact/'storage').rglob('*') if p.is_dir()), reverse=True) + [artifact/'storage']:
            directory_fd = verifier.open_directory(directory)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        manifest = dict(schemaVersion=1, createdAt=backup.utc_now().isoformat(),
                        database=backup.file_record(artifact/DB, artifact),
                        documents=[backup.file_record(p, artifact) for p in sorted((artifact/'storage').rglob('*')) if p.is_file()])
        durable_json(artifact/'manifest.json', manifest)
        result, code = verifier.verify(artifact, source_storage)
        report.update(status=result['status'], recoveryReady=result['recoveryReady'], verification=result)
        # Completion marker is last. A crashed/interrupted directory is never a
        # completed procedure; retain it as evidence, never reuse or auto-adopt it.
        durable_json(destination/'checkpoint-result.json', report)
        directory_fd = verifier.open_directory(destination)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        return report, code
    except Exception:
        report.update(status='invalid', recoveryReady=False, errorCode='wal_checkpoint_not_certified')
        return report, 1
    finally:
        if fd is not None:
            os.close(fd)
        if parent is not None:
            os.close(parent)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-bundle', required=True)
    parser.add_argument('--source-storage', required=True)
    parser.add_argument('--destination', required=True)
    args = parser.parse_args()
    report, code = generate(args.source_bundle, args.source_storage, args.destination)
    print(json.dumps(report, sort_keys=True))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
