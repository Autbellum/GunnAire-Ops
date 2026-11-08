"""Durable, bounded upload reservations. Never sweep or delete unknown files.

All managed writers hold a filesystem lock through file preparation and metadata
commit. A durable DB reservation precedes file creation, and persisted inode
ownership precedes payload writes. Only an identical authenticated retry may
resume a pending file. Pre-existing files without ownership proof fail closed.
"""
from dataclasses import dataclass
import fcntl
import hashlib
import os
from pathlib import Path
import stat
import uuid

MIB = 1024 * 1024
NAMESPACE = '.document-upload-v1'
TABLE = 'document_upload_reservations_v1'
METADATA_BYTES = MIB


class StorageAdmissionError(Exception):
    def __init__(self, message='Upload storage is unavailable; retain the original and retry later', status=503):
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class Policy:
    free_bytes: int = 256 * MIB
    pending_bytes: int = 256 * MIB
    pending_count: int = 128

    @classmethod
    def from_environment(cls):
        fields = (('GUNNAIRE_UPLOAD_FREE_RESERVE_BYTES', 256*MIB, 64*MIB, 1024**4),
                  ('GUNNAIRE_UPLOAD_PENDING_BYTES', 256*MIB, 1, 1024**3),
                  ('GUNNAIRE_UPLOAD_PENDING_COUNT', 128, 1, 1024))
        values = []
        for name, default, low, high in fields:
            raw = os.environ.get(name, str(default))
            if len(raw) > 20 or not raw.isascii() or not raw.isdecimal() or not low <= int(raw) <= high:
                raise StorageAdmissionError('Invalid upload disk policy')
            values.append(int(raw))
        return cls(*values)


def initialize(connection):
    connection.execute(f'''CREATE TABLE IF NOT EXISTS {TABLE}(
        id TEXT PRIMARY KEY, operation_id TEXT UNIQUE, actor TEXT NOT NULL,
        request_sha256 TEXT NOT NULL, expected_bytes INTEGER NOT NULL CHECK(expected_bytes > 0),
        file_sha256 TEXT NOT NULL, device INTEGER, inode INTEGER,
        CHECK((device IS NULL) = (inode IS NULL)))''')
    connection.execute(f'''CREATE TRIGGER IF NOT EXISTS document_upload_reservation_identity_immutable_v1
        BEFORE UPDATE OF id,operation_id,actor,request_sha256,expected_bytes,file_sha256 ON {TABLE}
        WHEN NEW.id IS NOT OLD.id OR NEW.operation_id IS NOT OLD.operation_id OR NEW.actor IS NOT OLD.actor
          OR NEW.request_sha256 IS NOT OLD.request_sha256 OR NEW.expected_bytes IS NOT OLD.expected_bytes
          OR NEW.file_sha256 IS NOT OLD.file_sha256
        BEGIN SELECT RAISE(ABORT, 'Upload reservation identity is immutable'); END''')


def write_payload(fd, data):
    """Pinned descriptor, bounded write chunks, durable before acknowledgement."""
    os.lseek(fd, 0, os.SEEK_SET)
    offset = 0
    view = memoryview(data)
    while offset < len(data):
        count = os.write(fd, view[offset:offset + MIB])
        if count <= 0:
            raise OSError('Incomplete upload write')
        offset += count
    os.fsync(fd)


class Admission:
    def __init__(self, db, root, db_path, policy=None):
        self.db, self.root, self.db_path = db, Path(root), Path(db_path)
        self.policy = policy or Policy.from_environment()
        self.root_fd = self.directory_fd = self.lock_fd = None

    def __enter__(self):
        try:
            self.root.mkdir(parents=True, exist_ok=True)
            # A configured root alias is permitted; children must not be symlinks.
            self.root = self.root.resolve(strict=True)
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            self.root_fd = os.open(self.root, flags)
            try:
                os.mkdir(NAMESPACE, 0o700, dir_fd=self.root_fd)
                os.fsync(self.root_fd)
            except FileExistsError:
                pass
            self.directory_fd = os.open(NAMESPACE, flags, dir_fd=self.root_fd)
            self._private(os.fstat(self.directory_fd), directory=True)
            self.lock_fd = os.open('.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=self.directory_fd)
            self._private(os.fstat(self.lock_fd))
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return self
        except (OSError, StorageAdmissionError) as error:
            self.__exit__(None, None, None)
            if isinstance(error, StorageAdmissionError):
                raise
            raise StorageAdmissionError() from None

    def __exit__(self, *_):
        for name in ('lock_fd', 'directory_fd', 'root_fd'):
            fd = getattr(self, name)
            if fd is not None:
                os.close(fd)
                setattr(self, name, None)

    @staticmethod
    def _private(info, directory=False):
        expected = 0o700 if directory else 0o600
        valid_type = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
        if (not valid_type or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != expected
                or not directory and info.st_nlink != 1):
            raise StorageAdmissionError('Upload ownership proof is unavailable; retain pending files')

    def _name(self, row):
        identifier = row['id']
        try:
            valid = isinstance(identifier, str) and str(uuid.UUID(identifier)) == identifier
        except (ValueError, TypeError, AttributeError):
            valid = False
        if not valid:
            raise StorageAdmissionError()
        return identifier + '.payload'

    def path(self, row):
        return self.root / NAMESPACE / self._name(row)

    def _assert_directory(self):
        current = os.stat(NAMESPACE, dir_fd=self.root_fd, follow_symlinks=False)
        held = os.fstat(self.directory_fd)
        self._private(current, directory=True)
        if (current.st_dev, current.st_ino) != (held.st_dev, held.st_ino):
            raise StorageAdmissionError()
        current_lock = os.stat('.lock', dir_fd=self.directory_fd, follow_symlinks=False)
        held_lock = os.fstat(self.lock_fd)
        self._private(current_lock)
        if (current_lock.st_dev, current_lock.st_ino) != (held_lock.st_dev, held_lock.st_ino):
            raise StorageAdmissionError('Upload admission lock changed; retain pending files')

    def _assert_unreferenced(self, row, connection):
        if connection.execute('SELECT 1 FROM documents WHERE id=? OR stored_path=?',
                              (row['id'], str(self.path(row)))).fetchone():
            raise StorageAdmissionError('Pending upload is already referenced; retain its file', 409)

    def _held_bytes(self, row):
        try:
            info = os.stat(self._name(row), dir_fd=self.directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            return 0
        self._private(info)
        if row['inode'] is None or (info.st_dev, info.st_ino) != (row['device'], row['inode']):
            raise StorageAdmissionError('Pending upload ownership is uncertain; retain its file')
        if info.st_size > row['expected_bytes']:
            raise StorageAdmissionError('Pending upload content changed; retain its file', 409)
        return info.st_size

    def _space(self, pending, additional):
        # Account for promised-but-not-yet-written bytes, not merely today's free
        # blocks. Written pending bytes already consume filesystem free space.
        outstanding = sum(row['expected_bytes'] - self._held_bytes(row) for row in pending)
        storage = os.fstatvfs(self.directory_fd)
        if storage.f_bavail * storage.f_frsize < self.policy.free_bytes + METADATA_BYTES + outstanding + additional:
            raise StorageAdmissionError('Upload disk reserve would be consumed; retain the original')
        db_parent = os.open(self.db_path.parent.resolve(), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            if os.fstat(db_parent).st_dev != os.fstat(self.directory_fd).st_dev:
                available = os.fstatvfs(db_parent)
                if available.f_bavail * available.f_frsize < self.policy.free_bytes + METADATA_BYTES:
                    raise StorageAdmissionError('Database disk reserve would be consumed; retain the original')
        finally:
            os.close(db_parent)

    def reserve(self, operation, actor, request_digest, size, digest):
        if type(size) is not int or size <= 0:
            raise StorageAdmissionError('Document is empty', 400)
        self._assert_directory()
        with self.db() as connection:
            rows = connection.execute(f'SELECT * FROM {TABLE} ORDER BY id LIMIT ?',
                                      (self.policy.pending_count + 1,)).fetchall()
            existing = connection.execute(f'SELECT * FROM {TABLE} WHERE operation_id=?', (operation,)).fetchone() if operation else None
            if existing and (existing['actor'], existing['request_sha256'], existing['expected_bytes'], existing['file_sha256']) != (actor, request_digest, size, digest):
                raise StorageAdmissionError('Pending upload conflicts with its original actor or request', 409)
            total = sum(row['expected_bytes'] for row in rows)
            if (len(rows) > self.policy.pending_count or total > self.policy.pending_bytes
                    or existing is None and (len(rows) >= self.policy.pending_count or total + size > self.policy.pending_bytes)):
                raise StorageAdmissionError('Pending upload capacity is full; recover existing operations first')
            self._space(rows, 0 if existing else size)
            if existing:
                self._assert_unreferenced(existing, connection)
                return dict(existing)
            identifier = str(uuid.uuid4())
            connection.execute(f'INSERT INTO {TABLE}(id,operation_id,actor,request_sha256,expected_bytes,file_sha256) VALUES(?,?,?,?,?,?)',
                               (identifier, operation, actor, request_digest, size, digest))
            return dict(connection.execute(f'SELECT * FROM {TABLE} WHERE id=?', (identifier,)).fetchone())

    def prepare(self, row, data):
        if len(data) != row['expected_bytes'] or hashlib.sha256(data).hexdigest() != row['file_sha256']:
            raise StorageAdmissionError('Original upload bytes do not match the reservation', 409)
        self._assert_directory()
        with self.db() as connection:
            self._assert_unreferenced(row, connection)
        name = self._name(row)
        fd = None
        try:
            try:
                fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.directory_fd)
                info = os.fstat(fd)
                os.fsync(self.directory_fd)
                # Commit ownership before any payload bytes. An interruption
                # before this commit leaves at most an empty uncertain file.
                with self.db() as connection:
                    updated = connection.execute(f'UPDATE {TABLE} SET device=?,inode=? WHERE id=? AND actor=? AND request_sha256=?',
                                                 (info.st_dev, info.st_ino, row['id'], row['actor'], row['request_sha256']))
                    if updated.rowcount != 1:
                        raise StorageAdmissionError('Upload reservation changed; retain the original')
                row.update(device=info.st_dev, inode=info.st_ino)
            except FileExistsError:
                fd = os.open(name, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.directory_fd)
            info = os.fstat(fd)
            self._private(info)
            if row['inode'] is None or (info.st_dev, info.st_ino) != (row['device'], row['inode']):
                raise StorageAdmissionError('Pending upload ownership is uncertain; retain its file')
            if info.st_size > len(data):
                raise StorageAdmissionError('Pending upload content changed; retain its file', 409)
            # A partial retry may continue only the exact original prefix. Never
            # truncate or overwrite differing pending evidence.
            offset = 0
            while offset < info.st_size:
                chunk = os.read(fd, min(MIB, info.st_size - offset))
                if not chunk or chunk != data[offset:offset+len(chunk)]:
                    raise StorageAdmissionError('Pending upload content changed; retain its file', 409)
                offset += len(chunk)
            if info.st_size < len(data):
                write_payload(fd, data)
            else:
                os.fsync(fd)
            self.validate(row)
            return self.path(row)
        except OSError:
            raise StorageAdmissionError() from None
        finally:
            if fd is not None:
                os.close(fd)

    def validate(self, row):
        self._assert_directory()
        if self._held_bytes(row) != row['expected_bytes']:
            raise StorageAdmissionError('Pending upload is incomplete; retain its file')

    def complete(self, row, connection):
        # Caller inserts the committed document in this very transaction.
        document = connection.execute('SELECT stored_path,file_size_bytes,file_sha256 FROM documents WHERE id=?', (row['id'],)).fetchone()
        if not document or tuple(document) != (str(self.path(row)), row['expected_bytes'], row['file_sha256']):
            raise StorageAdmissionError('Document commit does not match its reservation')
        removed = connection.execute(f'DELETE FROM {TABLE} WHERE id=? AND actor=? AND request_sha256=? AND device=? AND inode=?',
                                     (row['id'], row['actor'], row['request_sha256'], row['device'], row['inode']))
        if removed.rowcount != 1:
            raise StorageAdmissionError('Upload reservation changed before commit')
