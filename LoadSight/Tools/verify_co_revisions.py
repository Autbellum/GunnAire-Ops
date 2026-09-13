#!/usr/bin/env python3
"""Verify installed-plugin CO revision, history, stale protection and Word export."""
import hashlib
import json
import pathlib
import subprocess
import sys
import zipfile
import xml.etree.ElementTree as ET

plugin=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2]); out.mkdir(parents=True,exist_ok=False)
source=pathlib.Path('output/verification/co-word-release/Priced-credit-change-project.json').resolve()
source_hash=hashlib.sha256(source.read_bytes()).hexdigest()
wrapper=plugin/'scripts/loadsight.py'
def run(*args,success=True):
    r=subprocess.run([sys.executable,str(wrapper),*map(str,args)],capture_output=True,text=True)
    assert (r.returncode==0)==success,r.stderr
    return r.stdout
old=json.loads(run('change-review',source))[0]
request=json.loads(pathlib.Path('output/verification/co-word-release/Priced-credit-change-request.json').read_text())
request.update(operation='changeorder.revise',author='Synthetic reviser',id=old['record']['id'],expectedFingerprint=old['editFingerprint'],reason='Synthetic revised quote and route measurement')
draft=request['draft']; draft['proposedScope']='Corrected mechanical route under synthetic revision C.'
draft['costs'][1]['delta']={'amount':-60,'source':'Synthetic credit quote Q-03'}
draft['quantities'][0]['proposed']={'amount':60,'source':'Synthetic M101 C route'}
req=out/'revision-request.json';req.write_text(json.dumps(request,indent=2))
revised=out/'revised-project.json';run('apply',source,'--request',req,'--output',revised)
review=json.loads(run('change-review',revised))[0]
assert review['record']['id']==old['record']['id'] and review['record']['author']==old['record']['author']
assert review['review']['totalDelta']==53 and review['history'][0]['before']==old['record']
assert review['history'][0]['author']=='Synthetic reviser' and review['editFingerprint']!=old['editFingerprint']
assert review['record']['draft']['quantities'][0]['proposed']['amount']==60
stale=out/'stale-project.json';run('apply',revised,'--request',req,'--output',stale,success=False);assert not stale.exists()
word=out/'Revised-change-order.docx';run('co-docx',revised,'--co-id',old['record']['id'],'--output',word)
with zipfile.ZipFile(word) as z:
    assert z.testzip() is None
    for name in z.namelist():ET.fromstring(z.read(name))
    xml=z.read('word/document.xml').decode()
    for text in ['Recorded revisions','Synthetic reviser','Synthetic credit quote Q-03','Before total USD: 73.00','After total USD: 53.00','Synthetic M101 C route']:
        assert text in xml,text
assert hashlib.sha256(source.read_bytes()).hexdigest()==source_hash
(out/'review.json').write_text(json.dumps(review,indent=2))
summary={'installedPlugin':str(plugin),'sourceUnchanged':True,'stableIdentity':True,'creatorRetained':True,'beforeTotalUSD':73,'afterTotalUSD':53,'staleEditRejected':True,'historyWordExported':True}
(out/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary))
