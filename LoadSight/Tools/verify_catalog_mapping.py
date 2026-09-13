#!/usr/bin/env python3
"""Exercise the real plugin wrapper against synthetic project copies; no external catalog access."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

plugin, output = map(Path, sys.argv[1:3])
workspace = Path(__file__).resolve().parents[1]
output.mkdir(parents=True, exist_ok=False)
wrapper = plugin.resolve() / 'scripts/loadsight.py'
project = json.loads((workspace / 'Tests/LoadSightKitTests/Fixtures/Blank_Project.json').read_text())
project['name'] = 'Synthetic plugin catalog mapping'
project['items'] = [dict(id='CAT-1', description='Synthetic duct', unit='LF', lifecycle='NEW', quantity=10, scope='Base', quantityStatus='Review required', source='Synthetic drawing', priceSource='Labor basis remains separate', materialUnit=99, laborHoursUnit=None, subcontractUnit=None, otherUnit=None, wastePct=10)]
source = output / 'source.json'; source.write_text(json.dumps(project))
original = hashlib.sha256(source.read_bytes()).hexdigest()

def run(command, path, *args, ok=True):
    result = subprocess.run([sys.executable, str(wrapper), command, str(path), '--workspace', str(workspace), *map(str, args)], capture_output=True, text=True)
    if (result.returncode == 0) != ok:
        raise AssertionError(result.stdout + result.stderr)
    return json.loads(result.stdout) if ok else result.stderr

def review(path):
    return run('catalog-review', path)['items'][0]

catalog = dict(id='30000000-0000-4000-8000-000000000001', source='Synthetic catalog / account A', name='Synthetic five-foot duct', sku='SYN-5FT', supplier='Synthetic supplier', supplierPartNumber='PART-5', purchaseCost=50, updatedAt='2026-09-10T12:00:00Z')
mapping = dict(version=1, catalog=catalog, currency='USD', purchaseUnit='5-foot length', catalogUnitsPerTakeoffUnit=0.2, takeoffUnit='LF', itemDescription='Synthetic duct', lifecycle='NEW', basis='Synthetic compatibility and 0.2 lengths per LF')
current = source
requests = []
for index, cost in enumerate([50, None, 0, 'remove']):
    row = review(current)
    if cost != 'remove': mapping['catalog']['purchaseCost'] = cost
    request = dict(operation='catalog.material.update', id='CAT-1', author='Synthetic plugin recorder', reason='Reviewed synthetic mapping', expectedFingerprint=row['editFingerprint'], mapping=None if cost == 'remove' else mapping)
    request_path = output / f'request-{index}.json'; request_path.write_text(json.dumps(request)); requests.append(request_path)
    target = output / f'project-{index}.json'
    result = run('apply', current, '--request', request_path, '--output', target)
    assert result['recordID'] == 'CAT-1'
    result_row = review(target)
    expected = 10 if cost == 50 else None if cost is None else 0
    assert result_row['item']['materialUnit'] == expected
    assert result_row['item']['quantity'] == 10 and result_row['item']['laborHoursUnit'] is None
    assert len(result_row['history']) == index + 1
    assert result_row['mappingCurrent'] == (None if cost == 'remove' else True)
    current = target
# Old fingerprint must not replay; failed writes must leave no output.
stale = output / 'stale.json'
assert 'changed' in run('apply', current, '--request', requests[0], '--output', stale, ok=False)
assert not stale.exists()
# Existing output is never replaced.
before = current.read_bytes()
run('apply', source, '--request', requests[0], '--output', current, ok=False)
assert current.read_bytes() == before
# Nested typo and unsupported currency fail without output.
for key, value in [('unexpected', True), ('currency', 'CAD')]:
    request = json.loads(requests[0].read_text()); request['mapping'][key] = value
    bad = output / f'bad-{key}.json'; bad.write_text(json.dumps(request)); target = output / f'rejected-{key}.json'
    run('apply', source, '--request', bad, '--output', target, ok=False); assert not target.exists()
assert hashlib.sha256(source.read_bytes()).hexdigest() == original
summary = dict(status='passed', plugin=str(plugin.resolve()), transitions=4, historyCount=len(review(current)['history']), sourceSHA256=original, checks=['conversion', 'unknown versus zero', 'removal retains cost', 'stale rejection', 'no overwrite', 'strict nested fields', 'USD only', 'quantity/labor unchanged', 'source preserved'])
(output / 'summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
