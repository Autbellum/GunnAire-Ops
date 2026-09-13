#!/usr/bin/env python3
"""Exercise read-only supplied-record comparison through the actual plugin/shared CLI."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

plugin, project, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=False)
source = project.read_bytes()
parsed = json.loads(source)
items = parsed['items']
item = next(row for row in items if row.get('catalogMaterialMapping'))
saved = item['catalogMaterialMapping']['catalog']
changed = dict(saved, purchaseCost=(saved['purchaseCost'] or 0) + 25)
unknown = dict(saved, purchaseCost=None)
for name, records, status in [('unchanged',[saved],'unchanged'),('changed',[changed],'changed'),('unknown',[unknown],'changed' if saved['purchaseCost'] is not None else 'unchanged'),('missing',[],'missing'),('ambiguous',[changed,changed],'ambiguous')]:
    catalog = output / (name+'.json'); catalog.write_text(json.dumps(records))
    before = catalog.read_bytes()
    run = subprocess.run([sys.executable,str(plugin/'scripts/loadsight.py'),'catalog-compare',str(project),'--catalog',str(catalog)],capture_output=True,text=True)
    assert run.returncode == 0, run.stderr
    result = json.loads(run.stdout)
    row = next(row for row in result['items'] if row['itemID'] == item['id'])
    assert row['comparison']['status'] == status, row
    if name in ('unknown','missing','ambiguous'):
        assert row['comparison']['purchaseCostDelta'] is None
    assert project.read_bytes() == source
    assert catalog.read_bytes() == before
    (output/(name+'-review.json')).write_text(run.stdout)
bad = output/'invalid.json'; bad.write_text(json.dumps([dict(saved,purchasePrice=123)]))
run = subprocess.run([sys.executable,str(plugin/'scripts/loadsight.py'),'catalog-compare',str(project),'--catalog',str(bad)],capture_output=True,text=True)
assert run.returncode != 0 and not run.stdout.strip(), run
assert project.read_bytes() == source
summary = {'cases':5,'invalidRejected':True,'sourceSHA256':hashlib.sha256(source).hexdigest(),'mutations':0}
(output/'summary.json').write_text(json.dumps(summary,indent=2))
print(json.dumps(summary))
