#!/usr/bin/env python3
"""Verify actual plugin extraction and new-file RFI handoff using the synthetic drawing fixture."""
import base64
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
plugin, output = map(Path, sys.argv[1:]); output.mkdir(parents=True, exist_ok=False)
workspace = Path(__file__).resolve().parents[1]
fixture = workspace/'Tests/LoadSightKitTests/Fixtures/DrawingIntake.pdf'
original = fixture.read_bytes()
def run(command, source, *extra, ok=True):
    result = subprocess.run([sys.executable,str(plugin/'scripts/loadsight.py'),command,str(source),'--workspace',str(workspace),*map(str,extra)],capture_output=True,text=True)
    assert (result.returncode == 0) == ok, result.stderr
    return json.loads(result.stdout) if ok else None
fresh = run('extract-text',fixture)
assert fresh['candidates'] and fresh['pageCount']==3
assert all(c['matchedText'] in c['anchor']['text'] for c in fresh['candidates'])
records = run('ingest',fixture)
project = json.loads((workspace/'Reference/project/Blank_Project.json').read_text())
project['nativeDrawings'] = dict(schemaVersion=1,records=records,files={records[0]['id']:base64.b64encode(original).decode()})
source=output/'project.json';source.write_text(json.dumps(project));source_bytes=source.read_bytes()
review=run('extract-review',source);(output/'review.json').write_text(json.dumps(review,indent=2))
candidate=review['candidates'][0]
request=dict(operation='text.rfi.create',candidateID=candidate['id'],question='Confirm source applicability before using this occurrence.',impact='Quantity and equipment association remain unverified.',author='Synthetic plugin reviewer')
request_path=output/'request.json';request_path.write_text(json.dumps(request));target=output/'with-rfi.json'
result=run('apply',source,'--request',request_path,'--output',target)
updated=json.loads(target.read_text());rfi=next(x for x in updated['rfis'] if x['id']==result['recordID'])
assert rfi['status']=='Open' and candidate['id'] in rfi['source'] and records[0]['id'] in rfi['source']
assert updated['items']==project['items'] and updated['nativeDrawings']==project['nativeDrawings']
run('apply',source,'--request',request_path,'--output',target,ok=False)
stale=copy.deepcopy(request);stale['candidateID']='0'*64
stale_path=output/'stale.json';stale_path.write_text(json.dumps(stale));bad_output=output/'must-not-exist.json'
run('apply',source,'--request',stale_path,'--output',bad_output,ok=False)
assert not bad_output.exists() and fixture.read_bytes()==original and source.read_bytes()==source_bytes
summary=dict(candidates=len(review['candidates']),rfiID=result['recordID'],sourceSHA256=hashlib.sha256(original).hexdigest(),takeoffUnchanged=True,staleAndOverwriteRejected=True)
(output/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary))
