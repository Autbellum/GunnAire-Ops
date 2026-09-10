"""Bounded, descriptor-relative reads for authenticated company documents.

This is storage validation, never an authorization grant. Callers must authorize
the current session and document first. No symlink or special file is served.
"""
from __future__ import annotations

import errno
import os
from pathlib import Path
import re
import stat

MAX_BYTES = 64 * 1024 * 1024
_MIME = re.compile(r"[A-Za-z0-9!#$%&'*+.^_`|~-]+/[A-Za-z0-9!#$%&'*+.^_`|~-]+", re.ASCII)
FINANCIAL_KINDS = frozenset(("invoice", "estimate", "payment", "receipt", "bill", "financial",
                             "credit", "statement", "transaction", "maintenance_agreement"))
BILLING_ROLES = frozenset(("Admin", "Accounting", "Field Technician"))


class DocumentReadError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def header_text(value, maximum):
    return (type(value) is str and 0 < len(value.encode("utf-8")) <= maximum
            and value == value.strip() and all(ord(c) >= 32 and ord(c) != 127 for c in value))


def content_type(value):
    return header_text(value, 128) and _MIME.fullmatch(value) is not None


def financial_document(row):
    return bool(row["invoice_id"] or row["estimate_id"] or row["maintenance_contract_id"]
                or str(row["kind"] or "").strip().lower() in FINANCIAL_KINDS)


def read_document(storage_root: Path, stored_path, *, expected_bytes=None, maximum=MAX_BYTES):
    if (type(maximum) is not int or not 1 <= maximum <= MAX_BYTES
            or expected_bytes is not None and (type(expected_bytes) is not int or not 1 <= expected_bytes <= maximum)):
        raise DocumentReadError(409, "Document size is outside the supported limit.")
    descriptors = []
    try:
        # Resolve only the configured root; resolving the file before opening
        # would follow symlinks and leave a check/open race. Walk each component
        # under pinned directory descriptors instead (macOS and Linux).
        root = Path(storage_root).resolve(strict=True)
        path = Path(stored_path).expanduser().absolute()
        try:
            relative = path.relative_to(root)
        except ValueError:
            # Configured storage may itself have a canonical alias (/var on
            # macOS). The unresolved prefix is permitted, not file symlinks.
            relative = path.relative_to(Path(storage_root).expanduser().absolute())
        if not relative.parts or any(part in (".", "..") for part in relative.parts):
            raise DocumentReadError(403, "Document path is outside storage.")
        directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        descriptors.append(os.open(root, directory_flags))
        for part in relative.parts[:-1]:
            descriptors.append(os.open(part, directory_flags, dir_fd=descriptors[-1]))
        fd = os.open(relative.parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptors[-1])
        descriptors.append(fd)
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise DocumentReadError(403, "Only regular document files can be downloaded.")
        if before.st_size < 0 or before.st_size > maximum or expected_bytes is not None and before.st_size != expected_bytes:
            raise DocumentReadError(409, "Document size no longer matches the prepared content.")
        chunks, total = [], 0
        # Read at most the verified length plus one byte; handle short reads
        # without truncating output and reject a concurrent grow/shrink/write.
        while total <= before.st_size:
            block = os.read(fd, min(64 * 1024, before.st_size + 1 - total))
            if not block:
                break
            chunks.append(block)
            total += len(block)
        after = os.fstat(fd)
        fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if total != before.st_size or any(getattr(before, name) != getattr(after, name) for name in fields):
            raise DocumentReadError(409, "Document changed during the download. Refresh and retry.")
        return b"".join(chunks)
    except DocumentReadError:
        raise
    except (ValueError, TypeError):
        raise DocumentReadError(403, "Document path is outside storage.") from None
    except OSError as error:
        status = 403 if error.errno in (errno.ELOOP, errno.ENOTDIR, errno.EACCES, errno.EPERM) else 404
        raise DocumentReadError(status, "Document file is unavailable.") from None
    finally:
        for fd in reversed(descriptors):
            os.close(fd)
