#!/usr/bin/env python3
"""Exercise source-defined units against the real plugin and original synthetic PDF."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys

plugin, output = map(Path, sys.argv[1:]); output.mkdir(parents=True, exist_ok=False)
workspace = Path(__file__).resolve().parents[1]
fixtures = workspace / 'Tests/LoadSightKitTests/Fixtures'
pdf = fixtures / 'UnitConventionSchedule.pdf'
mapping = fixtures / 'UnitConventionScheduleMapping.json'
before = [p.read_bytes() for p in (pdf, mapping)]
request = json.loads(before[1])

def read(name, request, succeeds=True):
    path = output / (name + '.json'); path.write_text(json.dumps(request, indent=2))
    command = [sys.executable, str(plugin / 'scripts/loadsight.py'), 'schedule-text', str(pdf),
               '--schedule', str(path), '--workspace', str(workspace)]
    result = subprocess.run(command, capture_output=True, text=True)
    (output / (name + '.stderr.log')).write_text(result.stderr)
    assert (result.returncode == 0) == succeeds, (name, result.returncode, result.stderr)
    if succeeds:
        value = json.loads(result.stdout)
        (output / (name + '.review.json')).write_text(json.dumps(value, indent=2))
        return value
    assert not result.stdout.strip(), (name, 'invalid request returned review data')

unresolved = read('literal-only', request)
assert unresolved['numericReview'][0]['cells'][1]['status'] == 'unresolved'
source = 'Synthetic page 1 legend: MBH = 1000 BTU_IT/H; BTU denotes International Table units.'
request['regions'][0]['columns'][1]['unitDefinition'] = {
    'convention': 'thousandBtuInternationalTablePerHour', 'source': source}
resolved = read('source-defined', request)
assert [r['cells'][1]['text'] if 'text' in r['cells'][1] else None for r in resolved['rows']] == ['12', None, '30']
assert [r['cells'][1]['unitText'] for r in resolved['rows']] == ['MBH'] * 3
assert [r['cells'][1]['status'] for r in resolved['numericReview']] == ['interpreted', 'missing', 'interpreted']
assert abs(resolved['numericReview'][0]['cells'][1]['value'] - 3516.852842066667) < 1e-9
assert source in resolved['numericReview'][0]['cells'][1]['explanation']
assert resolved['rows'][0]['id'] != unresolved['rows'][0]['id']
assert resolved['rows'][0]['cells'][1]['unitDefinition']['source'] == source
request['regions'][0]['columns'][1]['unitDefinition']['source'] += ' Citation reviewed.'
revised = read('revised-citation', request)
assert revised['rows'][0]['id'] != resolved['rows'][0]['id']
for name, change in [
    ('missing-evidence', {'source': ''}),
    ('conflicting-convention', {'convention': 'usLiquidGallonsPerMinute'}),
    ('unknown-nested-field', {'assume': True})
]:
    invalid = copy.deepcopy(request)
    invalid['regions'][0]['columns'][1]['unitDefinition'].update(change)
    read(name, invalid, succeeds=False)
assert before == [p.read_bytes() for p in (pdf, mapping)]
summary = dict(rows=3, sourceConventionRequired=True, literalPreserved=True,
               changedEvidenceChangesRowID=True, invalidDefinitionsRejected=True,
               originalsUnchanged=True, sourceSHA256=hashlib.sha256(before[0]).hexdigest())
(output / 'summary.json').write_text(json.dumps(summary, indent=2)); print(json.dumps(summary))
