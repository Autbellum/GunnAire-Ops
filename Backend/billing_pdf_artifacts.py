"""Immutable, backup-covered billing PDF bytes for a server reservation.

The authenticated route must establish the current company, Google account,
revision, and lease before calling this store. File ownership is the server's:
two devices carrying the same reservation converge on one artifact path.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import uuid

try:
    from . import document_storage
except ImportError:
    import document_storage


MAX_PDF_BYTES = 25 * 1024 * 1024
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")


class ArtifactError(RuntimeError):
    pass


class BillingPDFArtifactStore:
    def __init__(self, storage_root: Path):
        self.storage_root = Path(storage_root)

    def save(self, reservation, data: bytes) -> tuple[int, str]:
        """Publish the reserved bytes once, with no replace or mutable alias."""
        company, artifact, digest = self._identity(reservation)
        if (type(data) is not bytes or not 5 <= len(data) <= MAX_PDF_BYTES or
                not data.startswith(b"%PDF-") or hashlib.sha256(data).hexdigest() != digest):
            raise ArtifactError("PDF bytes differ from the reserved content")
        folder = self._folder(company, create=True)
        target = folder / (artifact + ".pdf")
        temporary = folder / ("." + artifact + "-" + uuid.uuid4().hex + ".part")
        descriptor = None
        directory = None
        try:
            directory = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            descriptor = os.open(temporary.name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600,
                dir_fd=directory)
            view = memoryview(data)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise ArtifactError("Reserved PDF write did not make progress")
                view = view[written:]
            os.fsync(descriptor)
            os.close(descriptor)
            descriptor = None
            try:
                os.link(temporary.name, target.name, src_dir_fd=directory,
                    dst_dir_fd=directory, follow_symlinks=False)
            except FileExistsError:
                # Lost reply or concurrent device: the existing immutable file
                # must prove the exact same bytes before adoption.
                pass
            self._read(target, len(data), digest)
            os.fsync(directory)
            return len(data), digest
        except (OSError, document_storage.DocumentReadError) as error:
            raise ArtifactError("Reserved PDF storage is unavailable or differs") from error
        finally:
            if descriptor is not None:
                os.close(descriptor)
            if directory is not None:
                try:
                    os.unlink(temporary.name, dir_fd=directory)
                except FileNotFoundError:
                    pass
                except OSError:
                    pass
                os.close(directory)

    def read(self, reservation) -> bytes:
        company, artifact, digest = self._identity(reservation)
        target = self._folder(company, create=False) / (artifact + ".pdf")
        try:
            return self._read(target, None, digest)
        except (OSError, document_storage.DocumentReadError) as error:
            raise ArtifactError("Reserved PDF is missing or differs") from error

    def _read(self, target: Path, size: int | None, digest: str) -> bytes:
        data = document_storage.read_document(self.storage_root, target,
            expected_bytes=size, expected_sha256=digest, maximum=MAX_PDF_BYTES)
        if not data.startswith(b"%PDF-"):
            raise ArtifactError("Reserved PDF signature differs")
        return data

    def _folder(self, company: str, *, create: bool) -> Path:
        folder = self.storage_root / "billing-pdf-artifacts" / company
        current = self.storage_root
        try:
            if create:
                current.mkdir(mode=0o700, parents=True, exist_ok=True)
            for name in ("billing-pdf-artifacts", company):
                current = current / name
                if create:
                    current.mkdir(mode=0o700, exist_ok=True)
                if not current.is_dir() or current.is_symlink():
                    raise ArtifactError("Reserved PDF directory is unsafe")
        except OSError as error:
            raise ArtifactError("Reserved PDF directory is unavailable") from error
        return folder

    @staticmethod
    def _identity(reservation) -> tuple[str, str, str]:
        try:
            company = str(uuid.UUID(reservation.key.company_id))
            artifact = str(uuid.UUID(reservation.attachment_id))
            digest = reservation.content_digest
        except (AttributeError, TypeError, ValueError) as error:
            raise ArtifactError("Reserved PDF identity is invalid") from error
        if not isinstance(digest, str) or _SHA256.fullmatch(digest) is None:
            raise ArtifactError("Reserved PDF content proof is missing")
        return company, artifact, digest
