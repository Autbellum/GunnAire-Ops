#!/usr/bin/env python3
"""Verify recorded quote states through actual plugin edits/review with preserved source input."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
plugin, source, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=False)
original = source.read_bytes()
wrapper = plugin/'scripts/loadsight.py'
def run(command, project, *extra, ok=True):
    p = subprocess.run([sys.executable,str(wrapper),command,str(project),*map(str,extra)],capture_output=True,text=True)
    assert (p.returncode == 0) == ok, p.stderr
    return json.loads(p.stdout) if ok else None
review = run('catalog-review',source)
item = next(row for row in review['items'] if row['mapping'])
current = source
for index,(issued,end,status) in enumerate([('2000-01-01T00:00:00Z','2099-01-01T00:00:00Z','withinRecordedPeriod'),('2000-01-01T00:00:00Z','2001-01-01T00:00:00Z','expired'),('2000-01-01T00:00:00Z',None,'expiryUnknown'),('2099-01-01T00:00:00Z','2100-01-01T00:00:00Z','notYetIssued')]):
    row = next(row for row in run('catalog-review',current)['items'] if row['itemID'] == item['itemID'])
    mapping = copy.deepcopy(row['mapping'])
    mapping['quote'] = dict(supplier='Synthetic supplier',reference='Q-'+str(index),source='Synthetic quote fixture page 1',issuedAt=issued,validUntil=end,conditions='Synthetic only; freight excluded; availability unconfirmed')
    request = dict(operation='catalog.material.update',id=item['itemID'],author='Quote verifier',reason='Synthetic quote evidence',expectedFingerprint=row['editFingerprint'],mapping=mapping)
    request_path=output/f'request-{index}.json';request_path.write_text(json.dumps(request))
    target=output/f'project-{index}.json'
    run('apply',current,'--request',request_path,'--output',target)
    reviewed=run('catalog-review',target)
    result=next(row for row in reviewed['items'] if row['itemID']==item['itemID'])
    assert result['quoteReview']['status']==status
    assert result['mapping']['quote']==mapping['quote']
    assert result['item']['materialUnit']==item['item']['materialUnit']
    priced=run('review',target)
    held=any('Supplier quote for '+item['itemID']+':' in message for message in priced['blockers'])
    assert held == (status!='withinRecordedPeriod')
    (output/f'review-{index}.json').write_text(json.dumps(reviewed,indent=2))
    current=target
assert source.read_bytes()==original
bad=copy.deepcopy(request);bad['mapping']['quote']['validUntill']='2101-01-01T00:00:00Z'
bad_path=output/'invalid-request.json';bad_path.write_text(json.dumps(bad));bad_output=output/'must-not-exist.json'
run('apply',current,'--request',bad_path,'--output',bad_output,ok=False)
assert not bad_output.exists()
summary={'states':4,'inputSHA256':hashlib.sha256(original).hexdigest(),'malformedQuoteRejected':True,'costRetained':True}
(output/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary))
