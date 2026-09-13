#!/usr/bin/env python3
"""Exercise actual plugin map create/revise/read/remove and immutable source/history boundaries."""
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
fixture=fixtures/'EquipmentSchedule.pdf'; original=fixture.read_bytes()
mapping=json.loads((fixtures/'EquipmentScheduleMapping.json').read_text())
def run(command, source, *extra, ok=True):
    result=subprocess.run([sys.executable,str(plugin/'scripts/loadsight.py'),command,str(source),'--workspace',str(workspace),*map(str,extra)],capture_output=True,text=True)
    assert (result.returncode==0)==ok,result.stderr
    return json.loads(result.stdout) if ok else None
records=run('ingest',fixture)
project=json.loads((workspace/'Reference/project/Blank_Project.json').read_text())
project['nativeDrawings']=dict(schemaVersion=1,records=records,files={records[0]['id']:base64.b64encode(original).decode()})
source=output/'project-0.json';source.write_text(json.dumps(project));input_bytes=source.read_bytes()
state=run('schedule-map-review',source)
create=dict(operation='schedule.map.save',id=None,name='Synthetic schedule',request=mapping,expectedFingerprint=state['editFingerprint'],author='Synthetic mapper',reason='Map controlled headers')
def apply(request, source, suffix, ok=True):
    path=output/(suffix+'-request.json');path.write_text(json.dumps(request));target=output/(suffix+'.json')
    result=run('apply',source,'--request',path,'--output',target,ok=ok)
    if not ok:assert not target.exists()
    return target,result
first,response=apply(create,source,'project-1');identity=response['recordID']
review=run('schedule-map-review',first)
assert len(review['maps'])==1 and len(review['history'])==1
rows=run('schedule-saved',first,'--map-id',identity)
assert [r['tag'] for r in rows['rows']]==['RTU-1','EF-2','RTU-1']
revise=copy.deepcopy(create);revise.update(id=identity,name='Corrected synthetic schedule',expectedFingerprint=review['editFingerprint'],author='Synthetic checker',reason='Correct column edge');revise['request']['regions'][0]['columns'][2]['minX']=325
second,_=apply(revise,first,'project-2')
apply(revise,second,'stale',ok=False)
state=run('schedule-map-review',second)
assert len(state['history'])==2
assert state['history'][1]['before'][0]['request']['regions'][0]['columns'][2]['minX']==320
assert state['maps'][0]['request']['regions'][0]['columns'][2]['minX']==325
remove=dict(operation='schedule.map.remove',id=identity,expectedFingerprint=state['editFingerprint'],author='Synthetic checker',reason='Remove superseded working map')
third,_=apply(remove,second,'project-3');removed=run('schedule-map-review',third)
assert removed['maps']==[] and len(removed['history'])==3
run('schedule-saved',third,'--map-id',identity,ok=False)
invalid=copy.deepcopy(create);invalid['request']['regions'][0]['columns'][0]['typo']='bad'
apply(invalid,source,'invalid',ok=False)
for path in [first,second,third]:
    updated=json.loads(path.read_text())
    assert updated['nativeDrawings']==project['nativeDrawings'] and updated['items']==project['items']
    assert all(q['status']=='Open' for q in updated['qa'])
run('apply',source,'--request',output/'project-1-request.json','--output',first,ok=False)
assert source.read_bytes()==input_bytes and fixture.read_bytes()==original
summary=dict(mapID=identity,revisions=3,rowsBeforeRemoval=3,originalsAndQuantitiesUnchanged=True,staleMalformedAndOverwriteRejected=True,removedMapNotExtracted=True,sourceSHA256=hashlib.sha256(original).hexdigest())
(output/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary))
