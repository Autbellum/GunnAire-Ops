#!/usr/bin/env python3
"""Run the real iPad document workflow on an explicitly selected QA simulator."""
import argparse
import datetime
import json
import pathlib
import platform
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True, help='Available dedicated QA simulator UDID; no device data is erased')
parser.add_argument('--only-test', help='Optional LoadSightUITests/... test identifier')
args = parser.parse_args()
if args.only_test and not args.only_test.startswith('LoadSightUITests/'):
    parser.error('--only-test must identify the LoadSightUITests target')
workspace = pathlib.Path(__file__).resolve().parents[1]
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
selected = next((d for rows in devices['devices'].values() for d in rows if d['udid'] == args.device), None)
if not selected or not selected['name'].startswith('LoadSight QA'):
    parser.error('Choose an available dedicated simulator whose name starts with LoadSight QA.')
tag = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
root = workspace / 'output/verification/native-ui' / tag
root.mkdir(parents=True, exist_ok=False)
result = root / 'Interaction.xcresult'
command = ['xcodebuild', '-project', 'Native/LoadSight.xcodeproj', '-scheme', 'LoadSight',
           '-destination', f"platform=iOS Simulator,id={args.device},arch={platform.machine()}",
           '-derivedDataPath', '/tmp/gunnaire-loadsight-ui-tests', '-resultBundlePath', str(result),
           'CODE_SIGNING_ALLOWED=NO', 'test']
if args.only_test:
    command.append('-only-testing:' + args.only_test)
print(f"UI test log: {root / 'test.log'}", flush=True)
with (root / 'test.log').open('x') as stream:
    outcome = subprocess.run(command, cwd=workspace, stdout=stream, stderr=subprocess.STDOUT)
manifest = {'device': selected, 'command': command, 'exitCode': outcome.returncode,
            'resultBundle': str(result), 'scope': 'Assertions in Native/UITests/LoadSightUITests.swift; no broader acceptance implied'}
(root / 'run.json').write_text(json.dumps(manifest, indent=2))
if result.exists():
    exported = subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result),
                               '--output-path', str(root / 'attachments')], capture_output=True, text=True)
    (root / 'attachment-export.log').write_text(exported.stdout + exported.stderr)
print(json.dumps(manifest, indent=2))
sys.exit(outcome.returncode)
