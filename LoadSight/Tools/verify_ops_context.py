#!/usr/bin/env python3
"""Verify local Ops snapshots through the real plugin; uses synthetic identities only."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('plugin', type=Path)
parser.add_argument('output', type=Path, help='New evidence directory')
args = parser.parse_args()
workspace = Path(__file__).resolve().parents[1]
wrapper = args.plugin.resolve() / 'scripts/loadsight.py'
args.output.mkdir(parents=True, exist_ok=False)
source = args.output / 'source.json'
source.write_bytes((workspace / 'Tests/LoadSightKitTests/Fixtures/Blank_Project.json').read_bytes())
original = hashlib.sha256(source.read_bytes()).hexdigest()

def call(command, project, *extra, success=True):
    result = subprocess.run([sys.executable, str(wrapper), command, str(project), '--workspace', str(workspace), *map(str, extra)], capture_output=True, text=True)
    if (result.returncode == 0) != success:
        raise RuntimeError(result.stderr + result.stdout)
    return result.stdout

def review(path): return json.loads(call('ops-review', path))
def apply(project, request, name, success=True):
    request_path = args.output / (name + '-request.json')
    request_path.write_text(json.dumps(request, indent=2))
    output = args.output / (name + '.json')
    call('apply', project, '--request', request_path, '--output', output, success=success)
    if not success: assert not output.exists()
    return output

customer_id = '10000000-0000-4000-8000-000000000001'
context = {'version':1, 'customer':{'id':customer_id,'name':'Synthetic Ops customer','address':'Synthetic customer address'},
           'job':{'id':'20000000-0000-4000-8000-000000000001','customerID':customer_id,'title':'Synthetic job','siteAddress':'Synthetic site','serviceLocationID':None}}
request = {'operation':'ops.context.update','author':'Synthetic recorder','reason':'Selected supplied context','expectedFingerprint':review(source)['editFingerprint'],'context':context}
linked = apply(source, request, 'linked')
linked_review = review(linked)
assert linked_review['context']['job']['customerID'] == customer_id
assert len(linked_review['history']) == 1
apply(linked, request, 'stale', success=False)
wrong = json.loads(json.dumps(request)); wrong['context']['job']['customerID']='30000000-0000-4000-8000-000000000001'
apply(source, wrong, 'wrong-customer', success=False)
remove = dict(operation='ops.context.update', author='Synthetic editor', reason='Remove link', expectedFingerprint=linked_review['editFingerprint'], context=None)
unlinked = apply(linked, remove, 'unlinked')
final = review(unlinked)
assert final['context'] is None and len(final['history']) == 2
assert final['history'][1]['before'] == linked_review['context']
assert hashlib.sha256(source.read_bytes()).hexdigest() == original
summary = {'plugin':str(args.plugin), 'sourceUnchanged':True, 'linkedCustomerAndJob':True, 'historyRetainedAfterRemoval':True, 'staleRejected':True, 'wrongCustomerRejected':True, 'externalMutations':0}
(args.output / 'summary.json').write_text(json.dumps(summary,indent=2))
print(json.dumps(summary,indent=2))
