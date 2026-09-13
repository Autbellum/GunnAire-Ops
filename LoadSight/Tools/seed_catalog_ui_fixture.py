#!/usr/bin/env python3
"""Seed only the dedicated, synthetic catalog UI-test recovery scope in an installed simulator app.
Run after simctl install; refuses to overwrite a previous test result. No Ops database writes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import uuid
from datetime import datetime, timezone

STORE = '6A70B401-12A4-4779-BBC0-0AAFA681D499'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--device', required=True, help='Explicit iOS Simulator UDID')
a = p.parse_args()
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', a.device, 'com.gunnaire.businesssuite', 'data'], text=True).strip())
if 'CoreSimulator' not in container.parts:
    raise SystemExit('Expected an iOS Simulator application container')
root = json.loads((Path(__file__).resolve().parents[1] / 'Tests/LoadSightKitTests/Fixtures/Blank_Project.json').read_text())
root['name'] = 'Synthetic catalog UI project'
root['items'] = [dict(id='CAT-UI', description='Synthetic duct', unit='LF', scope='Base', lifecycle='NEW', quantity=10, quantityStatus='Review required', source='Synthetic drawing reference', materialUnit=10, laborHoursUnit=None, subcontractUnit=None, otherUnit=None, wastePct=None, priceSource='Labor costs not entered')]
catalog = dict(id='30000000-0000-4000-8000-000000000001', source='Synthetic UI catalog / account A', name='Synthetic five-foot duct', sku='UI-5FT', supplier='Synthetic supplier', supplierPartNumber='TEST-5FT', purchaseCost=50, updatedAt='2026-09-10T12:00:00Z')
mapping = dict(version=1, catalog=catalog, currency='USD', purchaseUnit='5-foot length', catalogUnitsPerTakeoffUnit=0.2, takeoffUnit='LF', itemDescription='Synthetic duct', lifecycle='NEW', basis='Synthetic initial unit conversion')
root['items'][0]['catalogMaterialMapping'] = mapping
now = datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')
root['catalogMaterialHistory'] = [dict(id=str(uuid.uuid4()), itemID='CAT-UI', author='Synthetic fixture', recordedAt=now, reason='UI test initial state', before=None, after=mapping, beforeMaterialUnit=None, afterMaterialUnit=10)]
digest = hashlib.sha256(('Ops-LoadSight-test/GunnAireUITest-' + STORE).encode()).hexdigest()
draft = dict(version=1, revision=str(uuid.uuid4()), scopeDigest=digest, savedAt=now, project=root, drawings=dict(schemaVersion=1, records=[], files={}))
directory = container / 'Library/Application Support/LoadSightRecovery'
directory.mkdir(parents=True, exist_ok=True, mode=0o700)
target = directory / (digest + '.json')
with target.open('x') as f:
    json.dump(draft, f, indent=2)
target.chmod(0o600)
print(json.dumps(dict(store=STORE, recovery=str(target), device=a.device)))
