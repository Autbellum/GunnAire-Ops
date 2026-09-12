import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify_release as release


class ReleaseVerificationTests(unittest.TestCase):
    def test_source_drift_fails_closed(self):
        for values in ((b'b' * 40, b''), (b'a' * 40, b' M changed.py')):
            with patch.object(release, 'git', side_effect=values):
                self.assertFalse(release.source_unchanged('a' * 40))
        with patch.object(release, 'git', side_effect=(b'a' * 40, b'')):
            self.assertTrue(release.source_unchanged('a' * 40))

    def test_relative_paths_reject_escape_and_ambiguous_separators(self):
        for name in ('/mnt/data/package', '../secret', 'a/../secret', 'a\\b', 'a\nb', ''):
            self.assertFalse(release.safe_relative(name))
        self.assertTrue(release.safe_relative('LocalAI/config/models.json'))

    def test_cumulative_package_has_verified_relative_checksums(self):
        files = {p: b'synthetic file\n' for p in release.REQUIRED}
        manifest = {'commit': 'a' * 40, 'version': release.VERSION}
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / 'release.zip'
            name, sha = release.package(files, manifest, target)
            self.assertEqual(name, 'release.zip')
            self.assertEqual(sha, release.digest(target.read_bytes()))
            with zipfile.ZipFile(target) as archive:
                for line in archive.read('SHA256SUMS').decode().splitlines():
                    expected, path = line.split('  ', 1)
                    self.assertTrue(release.safe_relative(path))
                    self.assertEqual(release.digest(archive.read(path)), expected)
                self.assertEqual(json.loads(archive.read('RELEASE_MANIFEST.json')), manifest)

    def test_package_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / 'release.zip'
            target.write_bytes(b'original')
            with self.assertRaises(FileExistsError):
                release.package({}, {'commit': 'a' * 40, 'version': release.VERSION}, target)
            self.assertEqual(target.read_bytes(), b'original')


if __name__ == '__main__':
    unittest.main()
