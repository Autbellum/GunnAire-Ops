#!/usr/bin/env python3
"""Create a local sourced schedule RFI through the plugin and verify immutable evidence."""
import base64
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys

plugin, output = map(Path, sys.argv[1:]); output.mkdir(parents=True, exist_ok=False)
workspace = Path(__file__).resolve().parents[1]; fixtures = workspace/'Tests/LoadSightKitTests/Fixtures'
pdf = fixtures/'ConsistencySchedule.pdf'; mapping = fixtures/'ConsistencyScheduleMapping.json'
def run(command, path, *extra, ok=True):
    p=subprocess.run([sys.executable,str(plugin/'scripts/loadsight.py'),command,str(path),'--workspace',str(workspace),*map(str,extra)],capture_output=True,text=True)
    assert (p.returncode==0)==ok,(p.returncode,p.stderr)
    return json.loads(p.stdout) if ok else None
records=run('ingest',pdf); review=run('schedule-text',pdf,'--schedule',mapping); row=review['rows'][0]
project=json.loads((workspace/'Reference/project/Blank_Project.json').read_text())
project['nativeDrawings']=dict(schemaVersion=1,records=records,files={records[0]['id']:base64.b64encode(pdf.read_bytes()).decode()})
source=output/'source.json';source.write_text(json.dumps(project));before=source.read_bytes()
request=dict(operation='schedule.rfi.create',author='Synthetic reviewer',request=json.loads(mapping.read_text()),rowID=row['id'],findingID='airflow.outdoorTotal',question='Confirm total and outdoor airflow rating basis.',impact='Equipment selection remains pending.')
req=output/'request.json';req.write_text(json.dumps(request));target=output/'with-rfi.json'
run('apply',source,'--request',req,'--output',target)
after=json.loads(target.read_text()); rfi=after['rfis'][-1]
assert rfi['status']=='Open' and rfi['response']=='' and row['id'] in rfi['source']
attachment=after['projectAttachments']['records'][0];data=base64.b64decode(attachment['data']);snapshot=json.loads(data)
assert hashlib.sha256(data).hexdigest()==attachment['id'] and attachment['id'] in rfi['source']
assert snapshot['row']==row and snapshot['finding']['id']=='airflow.outdoorTotal'
assert attachment['references'][0]['rfiID']==rfi['id']
assert after['nativeDrawings']==project['nativeDrawings'] and after['items']==project['items']
assert source.read_bytes()==before
for field,value in [('rowID','stale'),('findingID','invented'),('question',' '),('approval',True)]:
    bad=copy.deepcopy(request);bad[field]=value;path=output/(field+'.json');path.write_text(json.dumps(bad));destination=output/(field+'-must-not-exist.json')
    run('apply',source,'--request',path,'--output',destination,ok=False);assert not destination.exists()
run('apply',source,'--request',req,'--output',target,ok=False)
summary=dict(rfiID=rfi['id'],unanswered=True,evidenceSHA256=attachment['id'],snapshotMatchesOriginalRow=True,sourceAndQuantitiesUnchanged=True,invalidAndOverwriteRejected=True)
(output/'summary.json').write_text(json.dumps(summary,indent=2)); print(json.dumps(summary))
