#!/usr/bin/env python3
"""Exercise installed RFI routing edits and preserve a DOCX fixture for render QA."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('plugin', type=pathlib.Path)
parser.add_argument('output', type=pathlib.Path, help='New verification directory')
args = parser.parse_args()
workspace = pathlib.Path(__file__).resolve().parents[1]
args.output.mkdir(parents=True, exist_ok=False)
root = args.output.resolve()
wrapper = args.plugin.resolve() / 'scripts/loadsight.py'
source = workspace / 'Reference/project/Blank_Project.json'
source_hash = hashlib.sha256(source.read_bytes()).hexdigest()

def invoke(command, project, *extra):
    return subprocess.run([sys.executable, str(wrapper), command, str(project), '--workspace', str(workspace), *map(str, extra)], capture_output=True, text=True)

def apply(request, project, name, succeeds=True):
    req = root / (name + '-request.json'); out = root / (name + '.json')
    req.write_text(json.dumps(request, indent=2))
    result = invoke('apply', project, '--request', req, '--output', out)
    (root / (name + '.log')).write_text(result.stdout + result.stderr)
    if succeeds:
        assert result.returncode == 0, result.stderr
        return out, json.loads(result.stdout)['recordID']
    assert result.returncode != 0 and not out.exists(), result.stdout

base = dict(operation='rfi.create', author='Verification recorder', title='Clearance at beam', question='Please confirm the route at the beam and the access clearance.', source='Verification M101 detail 2', impact='Cost and schedule remain unknown until the route is confirmed.', priority='High', itemIDs=[])
communication = dict(to='Verification design team', **{'from': 'Verification mechanical estimator'}, date='2026-09-10', requiredResponseDate='2026-09-17', suggestedResolution='Consider the route shown on the section; confirm before procurement.')
first, identity = apply(dict(base, communication=communication), source, 'created')
second_values = dict(communication, to='Verification lead engineer', requiredResponseDate='2026-09-18')
edit = dict(base, operation='rfi.edit', id=identity)
second, _ = apply(dict(edit, communication=second_values), first, 'revised')
third, _ = apply(edit, second, 'older-client-edit')
assert json.loads(third.read_text())['rfis'][0]['to'] == second_values['to']
cleared, _ = apply(dict(edit, communication={key: '' for key in communication}), third, 'cleared')
doc = json.loads(cleared.read_text())
assert doc['rfis'][0]['to'] == '' and doc['rfiHistory'][-1]['before']['to'] == second_values['to']
for name, value in [('null', None), ('partial', {'to': 'Incomplete'}), ('bad-date', dict(communication, date='2026-02-30'))]:
    apply(dict(edit, communication=value), second, name, succeeds=False)
output = root / 'Routing-review.docx'
result = invoke('rfi-docx', second, '--rfi-id', identity, '--output', output)
assert result.returncode == 0, result.stderr
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    for name in archive.namelist(): ET.fromstring(archive.read(name))
    xml = archive.read('word/document.xml').decode()
    assert 'Verification design team' in xml and 'Verification lead engineer' in xml
    assert '2026-09-17' in xml and '2026-09-18' in xml
out_hash = hashlib.sha256(output.read_bytes()).hexdigest()
assert invoke('rfi-docx', second, '--rfi-id', identity, '--output', output).returncode != 0
assert hashlib.sha256(output.read_bytes()).hexdigest() == out_hash
assert hashlib.sha256(source.read_bytes()).hexdigest() == source_hash
summary = dict(createdAndRevised=True, omittedFieldsPreserved=True, explicitClearRetainsHistory=True, nullPartialAndInvalidDateRejected=True, docxCurrentAndHistoricalValues=True, overwriteRejected=True, originalUnchanged=True, docx=str(output))
(root / 'summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
