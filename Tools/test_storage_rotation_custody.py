import contextlib
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from cryptography.fernet import Fernet
from Tools.storage_rotation_custody import prepare


class CustodyTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        self.old={domain:Fernet.generate_key().decode() for domain in ('qbo','google','push')}

    def test_private_generation_retains_recovery_and_outputs_no_values(self):
        output=io.StringIO()
        with contextlib.redirect_stdout(output),contextlib.redirect_stderr(output):
            result=prepare(self.root,'rotation',self.old)
        self.assertEqual(output.getvalue(),'')
        self.assertEqual(result,{'custody_prepared':True,'live_credentials_changed':False})
        directory=self.root/'rotation';file=directory/'custody.json'
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode),0o700)
        self.assertEqual(stat.S_IMODE(file.stat().st_mode),0o600)
        bundle=json.loads(file.read_text())
        for domain,value in bundle['readers'].items():
            self.assertEqual(value['keys']['old'],self.old[domain])
            self.assertNotEqual(value['keys']['new'],self.old[domain])
            self.assertEqual((value['active'],value['write_format']),('old','legacy'))
            Fernet(value['keys']['new'])

    def test_no_overwrite_and_no_symlink_traversal(self):
        prepare(self.root,'rotation',self.old)
        before=(self.root/'rotation'/'custody.json').read_bytes()
        with self.assertRaises(ValueError):prepare(self.root,'rotation',self.old)
        self.assertEqual((self.root/'rotation'/'custody.json').read_bytes(),before)
        (self.root/'alias').symlink_to(self.root,target_is_directory=True)
        with self.assertRaises(ValueError):prepare(self.root/'alias','another',self.old)
        self.assertFalse((self.root/'another').exists())

    def test_reject_public_parent_and_bad_values_without_secret_diagnostics(self):
        self.root.chmod(0o755)
        with self.assertRaises(ValueError) as error:prepare(self.root,'rotation',self.old)
        for value in self.old.values():self.assertNotIn(value,str(error.exception))
        self.assertFalse((self.root/'rotation').exists())
        self.root.chmod(0o700)
        with self.assertRaises(ValueError):prepare(self.root,'rotation',{**self.old,'push':'invalid'})
        self.assertFalse((self.root/'rotation').exists())

if __name__=='__main__':unittest.main()
