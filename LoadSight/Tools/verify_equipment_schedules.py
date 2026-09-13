#!/usr/bin/env python3
"""Run real read-only plugin schedule extraction against a controlled source and portable project."""
import base64
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys

plugin, output = map(Path, sys.argv[1:]); output.mkdir(parents=True, exist_ok=False)
workspace = Path(__file__).resolve().parents[1]
fixtures = workspace/'Tests/LoadSightKitTests/Fixtures'
source = fixtures/'EquipmentSchedule.pdf'; mapping = fixtures/'EquipmentScheduleMapping.json'
original = source.read_bytes(); map_bytes = mapping.read_bytes()
def run(command, path, *extra, ok=True):
    result = subprocess.run([sys.executable,str(plugin/'scripts/loadsight.py'),command,str(path),'--workspace',str(workspace),*map(str,extra)],capture_output=True,text=True)
    assert (result.returncode == 0) == ok, result.stderr
    return json.loads(result.stdout) if ok else None
result = run('schedule-text',source,'--schedule',mapping)
assert [r['tag'] for r in result['rows']] == ['RTU-1','EF-2','RTU-1']
assert next(c for c in result['rows'][1]['cells'] if c['field']=='minimumCircuitAmpacity').get('text') is None
assert [t['matchedText'] for t in result['unmatchedTagOccurrences']] == ['AHU-9']
assert any('Repeated schedule tag RTU-1' in w for w in result['warnings'])
assert not result['unassigned']
records=run('ingest',source)
project=json.loads((workspace/'Reference/project/Blank_Project.json').read_text())
project['nativeDrawings']=dict(schemaVersion=1,records=records,files={records[0]['id']:base64.b64encode(original).decode()})
project_path=output/'project.json'; project_path.write_text(json.dumps(project)); before=project_path.read_bytes()
review=run('schedule-review',project_path,'--schedule',mapping)
assert review['rows']==result['rows']
assert review['numericReview']==result['numericReview']
assert [n['rowID'] for n in review['numericReview']]==[r['id'] for r in review['rows']]
air=next(c for c in review['numericReview'][0]['cells'] if c['field']=='airflow')
assert air['status']=='interpreted' and air['unit']=='m³/s' and abs(air['value']-0.56633693184)<1e-12
assert next(c for c in review['rows'][0]['cells'] if c['field']=='airflow')['text']=='1,200'
missing=next(c for c in review['numericReview'][1]['cells'] if c['field']=='minimumCircuitAmpacity')
assert missing['status']=='missing' and 'value' not in missing
(output/'review.json').write_text(json.dumps(review,indent=2))
for name,modify in [('stale',lambda r:r['regions'][0].update(sourceID='0'*64)),('overlap',lambda r:r['regions'][0]['columns'][1].update(minX=100)),('typo',lambda r:r.update(autor='typo'))]:
    bad=json.loads(map_bytes); modify(bad); path=output/(name+'.json');path.write_text(json.dumps(bad))
    run('schedule-review',project_path,'--schedule',path,ok=False)
run('schedule-review',project_path,'--schedule',mapping,'--output',output/'must-not-exist.json',ok=False)
assert not (output/'must-not-exist.json').exists()
assert project_path.read_bytes()==before and source.read_bytes()==original and mapping.read_bytes()==map_bytes
summary=dict(numericReviewMatchesLiteralRows=True,airflowConversionVerified=True,rows=len(review['rows']),repeatedTagFlagged=True,missingMCARemainsUnknown=True,unmatchedTag='AHU-9',originalsUnchanged=True,staleOverlapTypoAndOutputFlagsRejected=True,sourceSHA256=hashlib.sha256(original).hexdigest())
(output/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary))
