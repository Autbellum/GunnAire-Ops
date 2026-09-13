#!/usr/bin/env python3
"""Discover a controlled PDF through the real plugin, then use its editable map proposal."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

plugin, output = map(Path, sys.argv[1:]); output.mkdir(parents=True, exist_ok=False)
workspace = Path(__file__).resolve().parents[1]
pdf = workspace/'Tests/LoadSightKitTests/Fixtures/EquipmentSchedule.pdf'
before = pdf.read_bytes()

def run(name, command, source, *extra):
    result = subprocess.run([sys.executable, str(plugin/'scripts/loadsight.py'), command,
        str(source), *map(str,extra), '--workspace', str(workspace)], capture_output=True, text=True)
    (output/(name+'.stderr.log')).write_text(result.stderr)
    assert result.returncode == 0, result.stderr
    value = json.loads(result.stdout); (output/(name+'.json')).write_text(json.dumps(value,indent=2)); return value

found = run('discovery', 'schedule-discover', pdf)
assert found['pageCount'] == 1 and len(found['candidates']) == 1
candidate = found['candidates'][0]
assert [c['field'] for c in candidate['headers']] == ['tag', 'manufacturer', 'airflow', 'minimumCircuitAmpacity']
assert len(candidate['tagEvidence']) == 3
assert candidate['proposedRegion']['recordedBy'] == 'Automatic discovery — unreviewed'
assert all('unitDefinition' not in c for c in candidate['proposedRegion']['columns'])
assert 'unitText' not in candidate['headers'][-1]
request = output/'proposed-map.json';request.write_text(json.dumps(dict(schemaVersion=1,regions=[candidate['proposedRegion']]),indent=2))
rows = run('rows-from-proposal','schedule-text',pdf,'--schedule',request)
assert [r['tag'] for r in rows['rows']] == ['RTU-1','EF-2','RTU-1']
assert rows['rows'][0]['cells'][1]['text'] == 'Example Co'
assert rows['rows'][0]['cells'][2]['text'] == '1,200'
assert 'text' not in rows['rows'][1]['cells'][3]
assert pdf.read_bytes() == before
summary = dict(discoveredTables=1,rowsFromProposedMap=3,noMapInputRequired=True,
               originalPDFUnchanged=True,unknownMCAPreserved=True,noUnitConventionInvented=True,
               sourceSHA256=hashlib.sha256(before).hexdigest())
(output/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary))
