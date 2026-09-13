#!/usr/bin/env python3
"""Verify conditional schedule findings through the real plugin with a controlled PDF."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

plugin, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=False)
workspace = Path(__file__).resolve().parents[1]
fixtures = workspace / 'Tests/LoadSightKitTests/Fixtures'
pdf, mapping = fixtures / 'ConsistencySchedule.pdf', fixtures / 'ConsistencyScheduleMapping.json'
before = [p.read_bytes() for p in (pdf, mapping)]
command = [sys.executable, str(plugin/'scripts/loadsight.py'), 'schedule-text', str(pdf), '--schedule', str(mapping), '--workspace', str(workspace)]
process = subprocess.run(command, capture_output=True, text=True)
(output/'stderr.log').write_text(process.stderr)
assert process.returncode == 0, (process.returncode, process.stderr)
review = json.loads(process.stdout)
(output/'review.json').write_text(json.dumps(review, indent=2))
assert [r['rowID'] for r in review['consistencyReview']] == [r['id'] for r in review['rows']]
checks = [{c['id']:c for c in r['checks']} for r in review['consistencyReview']]
assert [c['airflow.outdoorTotal']['status'] for c in checks] == ['needsReview','unresolved','noConflict']
assert checks[1]['coordination.outdoorAir']['status'] == 'missing'
assert all(c['coordination.maximumOvercurrentProtection']['status']=='missing' for c in checks)
assert all(c['cooling.sensibleTotal']['status']=='unresolved' for c in checks)
assert 'same total airstream' in checks[0]['airflow.outdoorTotal']['detail']
assert next(c for c in review['rows'][0]['cells'] if c['field']=='outdoorAir')['text']=='1,800'
assert before == [p.read_bytes() for p in (pdf, mapping)]
summary=dict(rows=3,conditionalConflictMissingAndNoConflict=True,unmappedFieldsRemainUnknown=True,sourceBytesUnchanged=True,sourceSHA256=hashlib.sha256(before[0]).hexdigest())
(output/'summary.json').write_text(json.dumps(summary,indent=2)); print(json.dumps(summary))
