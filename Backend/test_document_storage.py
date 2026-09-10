from pathlib import Path
import os
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
