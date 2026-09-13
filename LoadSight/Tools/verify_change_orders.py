#!/usr/bin/env python3
"""Exercise the installed plugin with synthetic change data and preserve originals."""
import hashlib
import json
import pathlib
import subprocess
import sys

plugin = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=False)
source = pathlib.Path('Reference/project/Blank_Project.json').resolve()
original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
reference = (plugin / 'references/change-orders.md').read_text()
request = json.loads(reference.split('```json\n')[1].split('```')[0])
wrapper = plugin / 'scripts/loadsight.py'
def run(*args, success=True):
    result = subprocess.run([sys.executable, str(wrapper), *map(str,args)], capture_output=True, text=True)
    assert (result.returncode == 0) == success, result.stderr
    return result.stdout
request_path = out / 'unknown-request.json'; request_path.write_text(json.dumps(request, indent=2))
unknown = out / 'unknown-project.json'
run('apply', source, '--request', request_path, '--output', unknown)
unknown_review = json.loads(run('change-review', unknown))
assert unknown_review[0]['review'].get('totalDelta') is None
request['draft']['number'] = 'CO-002'
for row, value in zip(request['draft']['costs'], [100, -40, 0, 0]):
    row['delta'] = {'amount':value, 'source':'Synthetic quoted delta'}
request['draft']['markupPercent'] = {'amount':10, 'source':'Synthetic markup terms'}
request['draft']['markupBasis'] = 'positiveAdditionsOnly'
request['draft']['tax'] = {'amount':2, 'source':'Synthetic tax delta'}
request['draft']['bond'] = {'amount':1, 'source':'Synthetic bond delta'}
request['draft']['quantities'] = [{'name':'Duct', 'unit':'LF', 'original':{'amount':100, 'source':'Synthetic original M1'}, 'proposed':{'amount':70, 'source':'Synthetic revision M2'}}]
priced_request = out / 'priced-request.json'; priced_request.write_text(json.dumps(request, indent=2))
priced = out / 'priced-project.json'
run('apply', unknown, '--request', priced_request, '--output', priced)
review = json.loads(run('change-review', priced)); r = review[1]['review']
assert r['totalDelta'] == 73 and r['quantityDeltas'] == [-30] and r['status'] == 'Draft'
assert r['unknownFields'] and review[0]['review'].get('totalDelta') is None
(out / 'review.json').write_text(json.dumps(review, indent=2))
saved_hash = hashlib.sha256(priced.read_bytes()).hexdigest()
run('apply', unknown, '--request', priced_request, '--output', priced, success=False)
assert hashlib.sha256(priced.read_bytes()).hexdigest() == saved_hash
run('apply', priced, '--request', priced_request, '--output', out / 'duplicate.json', success=False)
assert not (out / 'duplicate.json').exists()
request['draft']['costs'][0]['delta']['typo'] = 1
bad = out / 'bad-request.json'; bad.write_text(json.dumps(request))
run('apply', source, '--request', bad, '--output', out / 'bad-project.json', success=False)
assert not (out / 'bad-project.json').exists()
assert hashlib.sha256(source.read_bytes()).hexdigest() == original_hash
summary = {'plugin': str(plugin), 'sourceSHA256': original_hash, 'unknownTotalWithheld': True, 'pricedDeltaUSD':73, 'quantityDeltaLF':-30, 'overwriteRejected':True, 'duplicateRejected':True, 'nestedTypoRejected':True, 'sourceUnchanged':True}
(out / 'summary.json').write_text(json.dumps(summary, indent=2)); print(json.dumps(summary))
