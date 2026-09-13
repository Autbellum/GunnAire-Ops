#!/usr/bin/env python3
"""Export synthetic CO Word fixtures using the installed plugin and verify contents."""
import hashlib
import json
import pathlib
import subprocess
import sys
import zipfile
import xml.etree.ElementTree as ET

plugin = pathlib.Path(sys.argv[1]); out = pathlib.Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=False)
source = pathlib.Path('Reference/project/Blank_Project.json').resolve()
source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
wrapper = plugin / 'scripts/loadsight.py'
def run(*args, success=True):
    r = subprocess.run([sys.executable, str(wrapper), *map(str,args)], capture_output=True, text=True)
    assert (r.returncode == 0) == success, r.stderr
    return r.stdout
request = json.loads((plugin/'references/change-orders.md').read_text().split('```json\n')[1].split('```')[0])
request['author'] = 'Synthetic estimator'
results = []
for name in ['Unknown-cost-change','Priced-credit-change']:
    d = request['draft']
    if name.startswith('Priced'):
        d.update(number='CO-002', date='2026-09-10', customer='Example GC — synthetic fixture', entitlement='Design revision', entitlementBasis='Synthetic design revision D2 issued for review', originalScope='Install the original mechanical duct route shown on synthetic drawing M101 revision A.', proposedScope='Relocate the duct route to the revised corridor shown on synthetic M101 revision B. Retain the specified air distribution performance and access provisions.', drawingRevision='Synthetic M101 revision B, detail 2', auditReference='Synthetic coordination audit A-02', timeImpact='Two additional working days requested; schedule agreement pending.', exclusions='Structural work and electrical trade work excluded.', approvalLanguage='Written authorization and agreed price and time adjustment are required before changed work proceeds.')
        d['quantities']=[{'name':'Rectangular supply duct','unit':'LF','original':{'amount':100,'source':'Synthetic M101 A measured route'},'proposed':{'amount':70,'source':'Synthetic M101 B measured route'}}]
        for row,value in zip(d['costs'],[100,-40,0,0]): row['delta']={'amount':value,'source':'Synthetic quote Q-02, '+row['category']+' change'}
        d['markupPercent']={'amount':10,'source':'Synthetic change pricing terms'}; d['markupBasis']='positiveAdditionsOnly'
        d['tax']={'amount':2,'source':'Synthetic tax delta'}; d['bond']={'amount':1,'source':'Synthetic bond delta'}
    req=out/(name+'-request.json'); req.write_text(json.dumps(request,indent=2))
    project=out/(name+'-project.json')
    created=json.loads(run('apply',source,'--request',req,'--output',project))
    before=hashlib.sha256(project.read_bytes()).hexdigest(); docx=out/(name+'.docx')
    run('co-docx',project,'--co-id',created['recordID'],'--output',docx)
    with zipfile.ZipFile(docx) as z:
        assert z.testzip() is None
        for item in z.namelist(): ET.fromstring(z.read(item))
        xml=z.read('word/document.xml').decode()
        assert 'Change order draft' in xml and 'Review copy awaiting approval' in xml
        assert 'Unknown — withheld' in xml if name.startswith('Unknown') else all(t in xml for t in ['73.00','-40.00','-30.0','Synthetic tax delta','Written authorization'])
        assert not any('TargetMode="External"' in z.read(i).decode() for i in z.namelist())
    run('co-docx',project,'--co-id',created['recordID'],'--output',docx,success=False)
    missing=out/(name+'-missing.docx'); run('co-docx',project,'--co-id','missing','--output',missing,success=False); assert not missing.exists()
    assert hashlib.sha256(project.read_bytes()).hexdigest()==before
    results.append({'document':str(docx),'projectSHA256':before,'overwriteRejected':True,'missingIDRejected':True,'XMLValid':True})
assert hashlib.sha256(source.read_bytes()).hexdigest()==source_hash
(out/'summary.json').write_text(json.dumps({'plugin':str(plugin),'sourceUnchanged':True,'exports':results},indent=2))
print(json.dumps(results))
