#!/usr/bin/env python3
"""Read-only verification of the controlled native map-authoring acceptance package."""
from pathlib import Path
import hashlib
import json
import sys

package=Path(sys.argv[1]); project=json.loads((package/'project.json').read_text()); records=json.loads((package/'drawings.json').read_text())
assert len(records)==1
record=records[0]; data=(package/'drawings'/record['id']).read_bytes()
expected=Path(__file__).resolve().parents[1]/'Tests/LoadSightKitTests/Fixtures/EquipmentSchedule.pdf'
assert data==expected.read_bytes() and hashlib.sha256(data).hexdigest()==record['id']
assert project.get('nativeDrawings') is None and project['items']==[]
assert all(g['status']=='Open' for g in project['qa'])
assert len(project['scheduleMaps'])==1 and len(project['scheduleMapHistory'])==1
saved=project['scheduleMaps'][0]; assert saved['name']=='Roof schedule'
region=saved['request']['regions'][0]
assert region['sourceID']==record['id'] and region['pageID']==record['id']+':1'
assert region['bodyBounds']==dict(x=40,y=520,width=480,height=160)
assert region['recordedBy']=='Synthetic mapper'
columns=region['columns']; assert len(columns)==2
assert columns[0]['field']=='tag' and columns[0]['minX']==40 and columns[0]['maxX']==160 and columns[0]['headerText']=='TAG'
assert columns[1]['field']=='airflow' and columns[1]['minX']==320 and columns[1]['maxX']==430 and columns[1]['headerText']=='CFM' and columns[1]['unitText']=='CFM'
history=project['scheduleMapHistory'][0]
assert history['before']==[] and history['after']==project['scheduleMaps'] and history['author']=='Synthetic mapper'
print(json.dumps(dict(package=str(package),mapID=saved['id'],sourceSHA256=record['id'],bodyAndColumnBoundsMatch=True,historyMatches=True,originalPDFUnchanged=True,takeoffStillEmpty=True)))
