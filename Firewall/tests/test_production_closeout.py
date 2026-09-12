"""Synthetic reporting installer/validation acceptance; never configures firewall."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import suricata_report as report
import validate_plan


class CloseoutTests(unittest.TestCase):
    def test_intervals_reject_bools_nonfinite_and_nonpositive(self):
        for value in (True, False, None, '1', 0, -1, float('inf'), float('nan')):
            self.assertFalse(validate_plan._positive(value))
        for value in (1, 0.25): self.assertTrue(validate_plan._positive(value))

    def test_source_collision_never_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'daily.json'; original = '{"event_type":"flow"}\n'; p.write_text(original)
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(report.main(['--input', str(p), '--json-output', str(p)]), 2)
            self.assertEqual(p.read_text(), original)

    def test_bad_line_limits_and_scalar_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'eve.json'; p.write_text('[]\n1\n{"event_type":"flow"}\n')
            summary = report.summarize(report.iter_events(p))
            self.assertEqual(summary['parse_errors'], 2)
            for limit in ('0', '-1'):
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(report.main(['--input', str(p), '--json-output', str(Path(tmp)/'out.json'), '--max-lines', limit]), 2)

    def test_timezone_order_and_markdown_injection(self):
        value = report.summarize([{'timestamp': '2026-09-12T12:00:00+02:00'}, {'timestamp': '2026-09-12T11:00:00Z'}])
        self.assertEqual(value['first_timestamp'], '2026-09-12T10:00:00Z')
        self.assertEqual(value['last_timestamp'], '2026-09-12T11:00:00Z')
        cell = report.markdown_cell('x\n# heading | [click](url) `code`')
        self.assertNotIn('\n', cell); self.assertIn('\\|', cell); self.assertIn('\\[', cell)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS installer only')
    def test_installations_have_private_distinct_keys_and_zero_exit(self):
        tokens=[]
        for _ in range(2):
            with tempfile.TemporaryDirectory() as tmp:
                home=Path(tmp); source=home/'eve.json'; source.write_text('{"dest_ip":"8.8.8.8"}\nnot-json\n')
                output=home/'reports'; env={**os.environ, 'HOME':tmp}
                run=subprocess.run(['/bin/bash', str(ROOT/'setup_local_reporting.sh'), '--eve-json', str(source), '--output-dir', str(output)],env=env,capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)
                key=home/'Library/Application Support/GunnAireFirewall/address-pseudonymization.key'
                self.assertEqual(key.stat().st_mode & 0o777,0o600)
                data=(output/'daily.json').read_text()
                self.assertNotIn(key.read_text().strip(),data)
                tokens.append(json.loads(data)['top_destinations'][0]['value'])
                self.assertEqual(source.read_text(),'{"dest_ip":"8.8.8.8"}\nnot-json\n')
        self.assertNotEqual(*tokens)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS installer only')
    def test_installer_rejects_collision_before_creating_support(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); source=root/'daily.json'; source.write_text('{}\n')
            run=subprocess.run(['/bin/bash',str(ROOT/'setup_local_reporting.sh'),'--eve-json',str(source),'--output-dir',tmp],env={**os.environ,'HOME':tmp},capture_output=True)
            self.assertNotEqual(run.returncode,0)
            self.assertEqual(source.read_text(),'{}\n')
            # macOS Python may initialize its own Library caches; the installer
            # must not create any of its support, key, or report destinations.
            self.assertFalse((root/'Library/Application Support/GunnAireFirewall').exists())
            self.assertFalse((root/'daily.md').exists())


if __name__ == '__main__': unittest.main()
