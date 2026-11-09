"""Exercise the actual repeat shell program: one failure must not skip evidence."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

class QuotaWorkflowProgressTests(unittest.TestCase):
    def test_repeats_finish_after_failure_and_keep_failing_exit(self):
        workflow=(Path(__file__).resolve().parents[1]/'.github/workflows/linux-quota-validation.yml').read_text()
        step=workflow.split('- name: Repeat unchanged maximum-size workload for allocation margin\n',1)[1].split('      - name:',1)[0]
        script='\n'.join(line[10:] for line in step.split('        run: |\n',1)[1].splitlines())
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);fake=root/'python';log=root/'attempts'
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$3" >> "$ATTEMPT_LOG"\ncase "$3" in *-2) exit 1;; esac\nexit 0\n')
            fake.chmod(0o700)
            result=subprocess.run(['bash','-c',script],env={**os.environ,'PATH':str(root)+':'+os.environ['PATH'],'ATTEMPT_LOG':str(log)},capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(log.read_text().splitlines(),['quota-evidence/upload-recovery-'+str(i) for i in (2,3,4,5)])
