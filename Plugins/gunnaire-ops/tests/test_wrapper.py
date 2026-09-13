"""Portable boundary checks; Swift engine correctness has its own test suite."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[1]
REPO = PLUGIN.parents[1]
WRAPPER = PLUGIN / "scripts/loadsight.py"

class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "project with spaces.json"
        self.project.write_text('{}')
        self.capture = self.root / "arguments.json"
        swift = self.root / "swift"
        swift.write_text('#!' + sys.executable + '\nimport json,os,sys\nopen(os.environ["CAPTURE"],"w").write(json.dumps(sys.argv[1:]))\nsys.exit(int(os.environ.get("SWIFT_EXIT","0")))\n')
        swift.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root)+os.pathsep+os.environ.get("PATH", ""), CAPTURE=str(self.capture))
        self.env.pop("LOADSIGHT_WORKSPACE", None)
    def run_wrapper(self, command="validate", *extra):
        return subprocess.run([sys.executable,str(WRAPPER),command,str(self.project),*map(str,extra)],env=self.env,capture_output=True,text=True)
    def test_schedule_discovery_is_read_only_and_requires_no_map(self):
        for command in ['schedule-discover', 'schedule-discover-review']:
            result = self.run_wrapper(command)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(self.capture.read_text())[-2:], [command, str(self.project.resolve())])
            self.capture.unlink()
            for option in ['--output', '--request', '--schedule', '--map-id', '--catalog', '--rfi-id', '--co-id']:
                self.assertNotEqual(self.run_wrapper(command, option, 'unused').returncode, 0)
                self.assertFalse(self.capture.exists())

    def test_checkout_discovery_and_argument_boundaries(self):
        result = self.run_wrapper()
        self.assertEqual(result.returncode,0,result.stderr)
        args = json.loads(self.capture.read_text())
        self.assertEqual(args, ['run','--package-path',str(REPO/'LoadSight'),'loadsight','validate',str(self.project.resolve())])
    def test_environment_and_explicit_workspace(self):
        alternate = self.root/'alternate package'; alternate.mkdir(); (alternate/'Package.swift').write_text('// fixture')
        self.env['LOADSIGHT_WORKSPACE']=str(alternate)
        self.assertEqual(self.run_wrapper().returncode,0)
        self.assertEqual(json.loads(self.capture.read_text())[2],str(alternate.resolve()))
        self.assertEqual(self.run_wrapper('validate','--workspace',REPO/'LoadSight').returncode,0)
        self.assertEqual(json.loads(self.capture.read_text())[2],str(REPO/'LoadSight'))
    def test_existing_output_and_symlink_fail_before_swift(self):
        output = self.root/'existing.docx'; output.write_bytes(b'original')
        result=self.run_wrapper('co-docx','--co-id','CO-1','--output',output)
        self.assertNotEqual(result.returncode,0); self.assertFalse(self.capture.exists()); self.assertEqual(output.read_bytes(),b'original')
        output.unlink(); output.symlink_to(self.root/'missing-target')
        self.assertNotEqual(self.run_wrapper('co-docx','--co-id','CO-1','--output',output).returncode,0)
        self.assertFalse(self.capture.exists())
    def test_invalid_flags_do_not_invoke_swift(self):
        self.assertNotEqual(self.run_wrapper('validate','--co-id','CO-1').returncode,0)
        self.assertFalse(self.capture.exists())
    def test_swift_failure_is_returned(self):
        self.env['SWIFT_EXIT']='7'
        self.assertEqual(self.run_wrapper().returncode,7)
    def test_xlsx_output_and_flag_boundaries(self):
        output = self.root/'new workbook.xlsx'
        result = self.run_wrapper('xlsx','--output',output)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(self.capture.read_text())[-3:],['xlsx',str(self.project.resolve()),str(output.absolute())])
        self.capture.unlink()
        self.assertNotEqual(self.run_wrapper('xlsx').returncode,0)
        self.assertNotEqual(self.run_wrapper('xlsx','--output',output,'--rfi-id','RFI-1').returncode,0)
        self.assertFalse(self.capture.exists())
        output.symlink_to(self.root/'missing.xlsx')
        self.assertNotEqual(self.run_wrapper('xlsx','--output',output).returncode,0)
        self.assertFalse(self.capture.exists())
    def test_catalog_compare_argument_and_mutation_boundaries(self):
        catalog = self.root/'supplied catalog.json'; catalog.write_text('[]')
        result = self.run_wrapper('catalog-compare','--catalog',catalog)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(self.capture.read_text())[-3:],['catalog-compare',str(self.project.resolve()),str(catalog.resolve())])
        self.capture.unlink()
        for command, flags in [('catalog-compare',[]),('catalog-compare',['--catalog',catalog,'--output',self.root/'out.json']),('validate',['--catalog',catalog])]:
            self.assertNotEqual(self.run_wrapper(command,*flags).returncode,0)
        self.assertFalse(self.capture.exists())
    def test_extraction_commands_are_read_only(self):
        for command in ['extract-text','extract-review']:
            result = self.run_wrapper(command)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(self.capture.read_text())[-2:],[command,str(self.project.resolve())])
            self.capture.unlink()
            self.assertNotEqual(self.run_wrapper(command,'--output',self.root/'out.json').returncode,0)
            self.assertFalse(self.capture.exists())
    def test_schedule_commands_require_read_only_mapping(self):
        mapping = self.root/'column map.json'; mapping.write_text('{}')
        for command in ['schedule-text','schedule-review']:
            result = self.run_wrapper(command,'--schedule',mapping)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(self.capture.read_text())[-3:],[command,str(self.project.resolve()),str(mapping.resolve())])
            self.capture.unlink()
            self.assertNotEqual(self.run_wrapper(command).returncode,0)
            self.assertNotEqual(self.run_wrapper(command,'--schedule',mapping,'--output',self.root/'out.json').returncode,0)
            self.assertFalse(self.capture.exists())
        self.assertNotEqual(self.run_wrapper('validate','--schedule',mapping).returncode,0)
        self.assertFalse(self.capture.exists())
    def test_saved_schedule_mapping_commands_are_read_only(self):
        identity = 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF'
        result = self.run_wrapper('schedule-saved','--map-id',identity)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(self.capture.read_text())[-3:],['schedule-saved',str(self.project.resolve()),identity])
        self.capture.unlink()
        self.assertNotEqual(self.run_wrapper('schedule-saved').returncode,0)
        self.assertNotEqual(self.run_wrapper('schedule-saved','--map-id',identity,'--output',self.root/'out.json').returncode,0)
        self.assertNotEqual(self.run_wrapper('validate','--map-id',identity).returncode,0)
        self.assertFalse(self.capture.exists())
        self.assertEqual(self.run_wrapper('schedule-map-review').returncode,0)
    def test_manifest_skill_directory_exists(self):
        manifest=json.loads((PLUGIN/'.codex-plugin/plugin.json').read_text())
        self.assertEqual(manifest['name'],'gunnaire-ops')
        self.assertTrue((PLUGIN/manifest['skills']).is_dir())
        self.assertEqual(len(list((PLUGIN/'skills').glob('*/SKILL.md'))),12)

if __name__ == '__main__': unittest.main()
