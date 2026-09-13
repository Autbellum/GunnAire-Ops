#!/usr/bin/env python3
"""Verify the controlled iPad-discovered map through portable plugin commands."""
from pathlib import Path
import base64
import hashlib
import json
import subprocess
import sys

package, plugin, output = map(Path, sys.argv[1:]); output.mkdir(parents=True, exist_ok=False)
workspace=Path(__file__).resolve().parents[1]
project=json.loads((package/'project.json').read_text());records=json.loads((package/'drawings.json').read_text())
assert len(records)==1
record=records[0]; original=(package/'drawings'/record['id']).read_bytes()
assert original==(workspace/'Tests/LoadSightKitTests/Fixtures/EquipmentSchedule.pdf').read_bytes()
assert hashlib.sha256(original).hexdigest()==record['id']
assert project['items']==[] and len(project['scheduleMaps'])==1 and len(project['scheduleMapHistory'])==1
saved=project['scheduleMaps'][0];assert saved['name']=='Discovered equipment'
assert saved['request']['regions'][0]['recordedBy']=='Synthetic reviewer'
assert 'Schedule header and tag alignment discovery v1' in saved['request']['regions'][0]['mappingBasis']
assert project['scheduleMapHistory'][0]['after']==project['scheduleMaps']
project['nativeDrawings']=dict(schemaVersion=1,records=records,files={record['id']:base64.b64encode(original).decode()})
portable=output/'native-project.json';portable.write_text(json.dumps(project,indent=2))
def run(name, command, *extra):
 result=subprocess.run([sys.executable,str(plugin/'scripts/loadsight.py'),command,str(portable),*extra,'--workspace',str(workspace)],capture_output=True,text=True)
 (output/(name+'.stderr.log')).write_text(result.stderr);assert result.returncode==0,result.stderr
 value=json.loads(result.stdout);(output/(name+'.json')).write_text(json.dumps(value,indent=2));return value
found=run('rediscovered','schedule-discover-review')
assert len(found['candidates'])==1
proposal=found['candidates'][0]['proposedRegion'];region=saved['request']['regions'][0]
assert proposal['columns']==region['columns'] and proposal['bodyBounds']==region['bodyBounds']
rows=run('saved-map','schedule-saved','--map-id',saved['id'])
assert [r['tag'] for r in rows['rows']]==['RTU-1','EF-2','RTU-1']
assert 'text' not in rows['rows'][1]['cells'][3]
summary=dict(package=str(package),nativeDiscoveredMapRetained=True,originalPDFUnchanged=True,
             authoredHistoryRetained=True,noPhysicalQuantitiesAdded=True,pluginRediscoveryAndSavedMapRead=True)
(output/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary))
