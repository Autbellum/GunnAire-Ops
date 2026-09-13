#!/usr/bin/env python3
"""Verify ordered dimension conversion through the real read-only plugin command."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
plugin, output = map(Path, sys.argv[1:]); output.mkdir(parents=True, exist_ok=False)
workspace=Path(__file__).resolve().parents[1]; fixtures=workspace/'Tests/LoadSightKitTests/Fixtures'
pdf, mapping=fixtures/'DimensionSchedule.pdf',fixtures/'DimensionScheduleMapping.json'
before=[p.read_bytes() for p in (pdf,mapping)]
p=subprocess.run([sys.executable,str(plugin/'scripts/loadsight.py'),'schedule-text',str(pdf),'--schedule',str(mapping),'--workspace',str(workspace)],capture_output=True,text=True)
(output/'stderr.log').write_text(p.stderr);assert p.returncode==0,(p.returncode,p.stderr)
review=json.loads(p.stdout);(output/'review.json').write_text(json.dumps(review,indent=2))
dimensions=review['dimensionReview']
assert [d['rowID'] for d in dimensions]==[r['id'] for r in review['rows']]
assert [d['interpretation']['status'] for d in dimensions]==['interpreted','missing','unresolved']
first=dimensions[0]['interpretation'];assert first['unit']=='m'
assert all(abs(a-b)<1e-12 for a,b in zip(first['components'],[0.6096,0.9144,1.2192])) and len(first['components'])==3
assert all('components' not in d['interpretation'] for d in dimensions[1:])
assert next(c for c in review['rows'][0]['cells'] if c['field']=='dimensions')['text']=='24 x 36 x 48'
assert before==[p.read_bytes() for p in (pdf,mapping)]
summary=dict(rows=3,orderedDimensionConversion=True,missingAndMalformedRemainUnknown=True,originalsUnchanged=True,sourceSHA256=hashlib.sha256(before[0]).hexdigest())
(output/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary))
