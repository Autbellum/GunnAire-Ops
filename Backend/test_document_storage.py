from pathlib import Path
import os
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from Backend import document_storage as storage


class DocumentStorageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.path = self.root / "document.pdf"
        self.path.write_bytes(b"original-file")

    def read(self, **kwargs):
        return storage.read_document(self.root, self.path, **kwargs)

    def rejected(self, status, action):
        with self.assertRaises(storage.DocumentReadError) as caught:
            action()
        self.assertEqual(caught.exception.status, status)

    def test_verified_read_releases_only_its_file_cache_without_changing_bytes(self):
        with mock.patch.object(os, "posix_fadvise", create=True) as advise, mock.patch.object(os, "POSIX_FADV_DONTNEED", 4, create=True):
            self.assertEqual(self.read(expected_sha256=hashlib.sha256(b"original-file").hexdigest()), b"original-file")
            advise.assert_called_once()
            self.assertEqual(advise.call_args.args[1:], (0, 0, 4))
            advise.reset_mock()
            self.rejected(409, lambda: self.read(expected_sha256="0" * 64))
            advise.assert_not_called()
        self.assertEqual(self.path.read_bytes(), b"original-file")

    def test_large_read_releases_copied_cache_windows_before_final_proof(self):
        data=b'm'*(3*1024*1024+17);self.path.write_bytes(data)
        calls=[]
        def advise(fd, offset, length, option):
            calls.append((offset,length,os.lseek(fd,0,os.SEEK_CUR)))
        with mock.patch.object(os,'posix_fadvise',side_effect=advise,create=True), mock.patch.object(os,'POSIX_FADV_DONTNEED',4,create=True):
            self.assertEqual(self.read(expected_sha256=hashlib.sha256(data).hexdigest()),data)
        windows=[call for call in calls if call[1]]
        self.assertEqual(windows,[(i*1024*1024,1024*1024,(i+1)*1024*1024) for i in range(3)])
        self.assertEqual(calls[-1],(0,0,len(data)))
        self.assertEqual(self.path.read_bytes(),data)
        with mock.patch.object(os,'posix_fadvise',create=True), mock.patch.object(os,'POSIX_FADV_DONTNEED',4,create=True):
            self.rejected(409,lambda:self.read(expected_sha256='0'*64))

    def test_cache_advice_failure_does_not_change_verified_content(self):
        with mock.patch.object(os, "posix_fadvise", side_effect=OSError("unsupported"), create=True), mock.patch.object(os, "POSIX_FADV_DONTNEED", 4, create=True):
            self.assertEqual(self.read(), b"original-file")

    def test_upload_write_is_flushed_before_sync_and_sync_failure_propagates(self):
        observed = []
        with mock.patch.object(os, "fsync", side_effect=lambda fd: observed.append(self.path.read_bytes())):
            storage.write_document_bytes(self.path, b"replacement")
        self.assertEqual(observed, [b"replacement"])
        with mock.patch.object(os, "fsync", side_effect=OSError("disk failure")):
            with self.assertRaises(OSError): storage.write_document_bytes(self.path, b"retained")
        self.assertEqual(self.path.read_bytes(), b"retained")

    def test_maximum_verified_document_avoids_a_second_full_size_buffer(self):
        # Isolate allocator telemetry from other tests and fixture server threads.
        block = b"x" * (1024 * 1024)
        digest = hashlib.sha256()
        with self.path.open("wb") as output:
            for _ in range(64):
                output.write(block)
                digest.update(block)
        code = """
from pathlib import Path
import hashlib,json,sys,tracemalloc
from Backend import document_storage
tracemalloc.start()
data=document_storage.read_document(Path(sys.argv[1]),sys.argv[2],
    expected_bytes=64*1024*1024,expected_sha256=sys.argv[3])
current,peak=tracemalloc.get_traced_memory()
print(json.dumps(dict(size=len(data),digest=hashlib.sha256(data).hexdigest(),peak=peak)))
"""
        result = subprocess.run([sys.executable, "-c", code, str(self.root),
                                 str(self.path), digest.hexdigest()],
                                cwd=Path(__file__).resolve().parents[1],
                                capture_output=True, text=True, check=True, timeout=30)
        measured = json.loads(result.stdout)
        self.assertEqual(measured["size"], 64 * 1024 * 1024)
        self.assertEqual(measured["digest"], digest.hexdigest())
        self.assertLess(measured["peak"], 96 * 1024 * 1024,
                        "Verified reads must not hold two full document buffers")

    def test_exact_bytes_and_short_reads(self):
        original_read = os.read
        with mock.patch.object(os, "read", side_effect=lambda fd, count: original_read(fd, min(count, 2))):
            self.assertEqual(self.read(expected_bytes=13), b"original-file")

    def test_relative_storage_configuration_preserves_existing_downloads(self):
        # The backend's default storage setting is relative to its launch cwd.
        relative_root = Path(os.path.relpath(self.root))
        self.assertEqual(storage.read_document(relative_root, relative_root / self.path.name), b"original-file")
        self.rejected(403, lambda: storage.read_document(relative_root,
            relative_root / ".." / self.root.name / self.path.name))

    def test_size_limits_before_reading_or_allocation(self):
        for kwargs in ({"expected_bytes": 12}, {"maximum": 4}, {"maximum": True},
                       {"expected_bytes": 0}, {"expected_bytes": storage.MAX_BYTES + 1}):
            with self.subTest(kwargs=kwargs), mock.patch.object(os, "read") as read:
                self.rejected(409, lambda: self.read(**kwargs))
                read.assert_not_called()

    def test_symlink_leaf_and_parent_rejected(self):
        folder = self.root / "nested"
        folder.mkdir()
        (folder / "alias.pdf").symlink_to(self.path)
        (self.root / "alias").symlink_to(folder, target_is_directory=True)
        for path in (folder / "alias.pdf", self.root / "alias" / "alias.pdf"):
            self.rejected(403, lambda: storage.read_document(self.root, path))

    def test_parent_swap_cannot_escape_pinned_directory(self):
        folder = self.root / "nested"
        folder.mkdir()
        (folder / "file.pdf").write_bytes(b"authorized")
        outside = self.root / "foreign"
        outside.mkdir()
        (outside / "file.pdf").write_bytes(b"not-authorized")
        original_open = os.open
        swapped = False
        def opening(path, flags, *args, **kwargs):
            nonlocal swapped
            if path == "file.pdf" and not swapped:
                swapped = True
                folder.rename(self.root / "original")
                folder.symlink_to(outside, target_is_directory=True)
            return original_open(path, flags, *args, **kwargs)
        with mock.patch.object(os, "open", side_effect=opening):
            self.assertEqual(storage.read_document(self.root, folder / "file.pdf"), b"authorized")

    def test_traversal_and_special_files_rejected_without_blocking(self):
        fifo = self.root / "pipe"
        os.mkfifo(fifo)
        for path in (fifo, self.root, self.root / ".." / self.root.name / "document.pdf"):
            self.rejected(403, lambda: storage.read_document(self.root, path))
        self.rejected(404, lambda: storage.read_document(self.root, self.root / "missing"))

    def test_growing_shrinking_or_rewriting_during_read_rejected(self):
        for replacement in (b"new", b"same-size-new!", b"new-longer-document"):
            self.path.write_bytes(b"original-file")
            original_read = os.read
            calls = []
            def read(fd, count):
                calls.append(count)
                if len(calls) == 1:
                    self.path.write_bytes(replacement)
                return original_read(fd, count)
            with mock.patch.object(os, "read", side_effect=read):
                self.rejected(409, self.read)
            self.assertLessEqual(sum(calls), 28)

    def test_header_policy_is_bounded_and_shared(self):
        self.assertTrue(storage.content_type("application/pdf"))
        self.assertTrue(storage.content_type("image/svg+xml"))
        for value in ("application/pdf\r\nX: yes", "text/plain\x00", "plain", "a/" + "b" * 128):
            self.assertFalse(storage.content_type(value))
        for value in ("x\n.pdf", "x\r.pdf", "x\x00.pdf", "x\x7f.pdf", "x" * 256):
            self.assertFalse(storage.header_text(value, 255))

    def test_same_size_replacement_before_first_read_rejected_by_upload_digest(self):
        digest = hashlib.sha256(b"original-file").hexdigest()
        self.path.write_bytes(b"modified-file")
        self.assertEqual(len(b"original-file"), len(b"modified-file"))
        self.rejected(409, lambda: self.read(expected_bytes=13, expected_sha256=digest))
        self.assertEqual(self.path.read_bytes(), b"modified-file", "Retain the evidence; do not repair or rewrite it")

    def test_digest_matches_exact_upload_bytes_with_short_reads(self):
        digest = hashlib.sha256(b"original-file").hexdigest()
        original = os.read
        with mock.patch.object(os, "read", side_effect=lambda fd, count: original(fd, min(count, 2))):
            self.assertEqual(self.read(expected_bytes=13, expected_sha256=digest), b"original-file")
        for invalid in (True, "a" * 63, "A" * 64, "g" * 64, ""):
            with mock.patch.object(os, "read") as reader:
                self.rejected(503, lambda: self.read(expected_sha256=invalid))
                reader.assert_not_called()
