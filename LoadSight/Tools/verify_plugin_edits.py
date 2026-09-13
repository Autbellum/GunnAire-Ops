#!/usr/bin/env python3
"""Exercise an installed plugin against temporary fixture copies, never production projects."""
import argparse
import base64
import hashlib
import json
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('plugin', type=pathlib.Path)
args = parser.parse_args()
workspace = pathlib.Path(__file__).resolve().parents[1]
wrapper = args.plugin / 'scripts/loadsight.py'
fixture = workspace / 'Reference/project/Blank_Project.json'
original_hash = hashlib.sha256(fixture.read_bytes()).hexdigest()

def call(command, project, *extra):
    return subprocess.run(['python3', str(wrapper), command, str(project), '--workspace', str(workspace), *map(str, extra)], text=True, capture_output=True)

with tempfile.TemporaryDirectory(prefix='plugin-edits-', dir=workspace / 'output/verification') as directory:
    root = pathlib.Path(directory)
    source = root / 'input.json'
    seed = json.loads(fixture.read_text())
    seed['items'] = [{'id': 'FIXTURE-1', 'description': 'Fixture duct', 'quantity': 10, 'unit': 'LF', 'scope': 'Base', 'source': 'Fixture route', 'quantityStatus': 'Measured-draft'}]
    source.write_text(json.dumps(seed))
    identity = None
    operations = [
        dict(operation='rfi.create', title='Fixture size conflict', question='Which duct size applies?', source='Fixture M101/M601', impact='Unknown pending answer', priority='High', itemIDs=[]),
        dict(operation='rfi.edit', title='Fixture size conflict', question='Which duct size applies after addendum?', source='Fixture M101/M601', impact='Unknown pending answer', priority='High', itemIDs=[]),
        dict(operation='rfi.resolve', response='Fixture 12 inch', responseSource='Fixture engineer answer', respondent='Fixture engineer'),
        dict(operation='rfi.reopen', reason='Fixture addendum requires review'),
        dict(operation='commercial.update', name='Integration fixture', estimator='Fixture estimator', basis='Fixture labor quote', fields={'laborRate': 125, 'customer': 'Fixture customer'}),
        dict(operation='proposal.update', source='Fixture terms', fields={'address': 'Fixture address', 'exclusions': 'Fixture trade exclusions'}),
        dict(operation='item.review', id='FIXTURE-1', scope='Base', status='Cross-checked', allowanceNote='', evidence='Fixture route check'),
        dict(operation='attachment.add', filename='fixture.txt', dataBase64=base64.b64encode(b'Fixture evidence').decode(), source='Fixture attachment', rfiID=None),
        dict(operation='aircondition.create', name='Fixture inlet', source='Fictional summer condition', dryBulbC=30, relativeHumidity=0.5, pressurePa=101325, dryBulbClassification='USER-PROVIDED', humidityClassification='USER-PROVIDED', pressureClassification='ENGINEERING-ASSUMPTION'),
        dict(operation='aircondition.create', name='Fixture outlet', source='Fictional coil leaving condition', dryBulbC=15, relativeHumidity=0.9, pressurePa=101325, dryBulbClassification='USER-PROVIDED', humidityClassification='USER-PROVIDED', pressureClassification='ENGINEERING-ASSUMPTION'),
        dict(operation='airprocess.create', name='Fixture mixing', source='Fictional actual inlet flows', kind='Mixed air', firstActualCFM=1000, secondActualCFM=200, flowClassification='USER-PROVIDED'),
        dict(operation='aircondition.derive', name='Fixture mixed output', source='Modeled full-stream coil inlet'),
        dict(operation='airprocess.create', name='Fixture cooling', source='Fictional actual coil inlet flow', kind='Cooling coil', firstActualCFM=1200, secondActualCFM=None, flowClassification='USER-PROVIDED'),
        dict(operation='aircondition.create', name='Fixture wet bulb', source='Fictional coincident design wet bulb', dryBulbC=35, humidityInput={'kind':'wetBulbC','value':24}, pressurePa=101325, dryBulbClassification='USER-PROVIDED', humidityClassification='EXTRACTED', pressureClassification='ENGINEERING-ASSUMPTION'),
        dict(operation='aircondition.create', name='Fixture dew point', source='Fictional dew point', dryBulbC=25, humidityInput={'kind':'dewPointC','value':10}, pressurePa=101325, dryBulbClassification='USER-PROVIDED', humidityClassification='EXTRACTED', pressureClassification='ENGINEERING-ASSUMPTION'),
        dict(operation='assembly.create', name='Fixture wood wall', source='Synthetic analytical example', construction='Wood framed', filmBasis='Fictional complete resistances; no automatic films', paths=[
            dict(name=name, fraction=fraction, fractionSource='Synthetic area split', fractionClassification='ENGINEERING-ASSUMPTION', layers=[
                dict(name='Common', resistance=1, source='Synthetic only', classification='ENGINEERING-ASSUMPTION'),
                dict(name='Core', resistance=r, source='Synthetic only', classification='ENGINEERING-ASSUMPTION')])
            for name,fraction,r in [('Cavity',0.75,19),('Framing',0.25,4)]]),
        dict(operation='room.transmission.create', name='Fixture room', source='Synthetic coincident design case', indoorDesignF={'value':70,'source':'Fixture room temperature','classification':'ENGINEERING-ASSUMPTION'}, surfaces=[]),
        dict(operation='room.transmission.create', name='Fixture rated room', source='Synthetic rated opening design case', indoorDesignF={'value':70,'source':'Fixture room temperature','classification':'ENGINEERING-ASSUMPTION'}, surfaces=[]),
        dict(operation='room.transmission.revise', reason='Fixture corrected indoor temperature'),
        dict(operation='qa.review', id='QA-01', complete=True, evidence='Fixture source inventory')
    ]
    for index, request in enumerate(operations):
        request['author'] = 'Fixture recorder'
        if identity and request['operation'].startswith('rfi.'):
            request['id'] = identity
        if request['operation'] == 'room.transmission.create':
            assembly_id = json.loads(source.read_text())['envelopeAssemblies'][0]['id']
            def scalar(value):
                return {'value':value,'source':'Synthetic fixture','classification':'ENGINEERING-ASSUMPTION'}
            request['surfaces'] = [dict(name='Outside wall', assemblyID=assembly_id, grossAreaSF=scalar(200), openings=[dict(name='Window',areaSF=scalar(30)),dict(name='Door',areaSF=scalar(20))], adjacentDesignF=scalar(10)),
                                   dict(name='Warmer partition', assemblyID=assembly_id, grossAreaSF=scalar(100), openings=[], adjacentDesignF=scalar(80))]
        if request['operation'] == 'room.transmission.create' and request['name'] == 'Fixture rated room':
            request['surfaces'][0]['openings'][0]['wholeProductU'] = scalar(0.3)
            request['surfaces'][0]['openings'][1]['wholeProductU'] = scalar(0.5)
        if request['operation'] == 'room.transmission.revise':
            current = call('room-review', source)
            assert current.returncode == 0, current.stderr
            target = next(row for row in json.loads(current.stdout)['rooms'] if row['record']['name'] == 'Fixture rated room')
            request.update({key:target['record'][key] for key in ['name','source','indoorDesignF','surfaces']})
            request['id'] = target['record']['id']
            request['expectedFingerprint'] = target['editFingerprint']
            request['indoorDesignF']['value'] = 75
            request['indoorDesignF']['source'] = 'Synthetic corrected setpoint'
        if request['operation'] == 'aircondition.derive':
            request['processID'] = json.loads(source.read_text())['airProcesses'][0]['id']
        if request['operation'] == 'airprocess.create':
            air = json.loads(source.read_text())['airConditions']
            request['firstConditionID'], request['secondConditionID'] = air[0]['id'], air[1]['id']
            if request['kind'] == 'Cooling coil':
                derived = next(row for row in air if row.get('derivation'))
                request['firstConditionID'] = derived['id']
                request['firstActualCFM'] = derived['derivation']['actualCFM']
                request['flowClassification'] = 'ENGINEERING-ASSUMPTION'
                request['source'] = 'Full modeled mixed-stream outlet flow'
        request_path = root / f'request-{index}.json'
        request_path.write_text(json.dumps(request))
        if request['operation'] == 'room.transmission.revise':
            stale_revision_request = request_path
        output = root / f'project-{index}.json'
        result = call('apply', source, '--request', request_path, '--output', output)
        assert result.returncode == 0, result.stderr
        receipt = json.loads(result.stdout)
        assert receipt['status'] == 'saved' and output.is_file()
        if receipt['recordID'] and request['operation'].startswith('rfi.'):
            identity = receipt['recordID']
        source = output
    project = json.loads(source.read_text())
    assert len(project['rfiHistory']) == 4
    assert len(project['commercialHistory']) == 1
    assert project['rfis'][0]['status'] == 'Open'
    assert project['inputs']['laborRate'] == 125
    assert project['proposalDetails']['address'] == 'Fixture address'
    assert project['items'][0]['quantityStatus'] == 'Cross-checked'
    assert base64.b64decode(project['projectAttachments']['records'][0]['data']) == b'Fixture evidence'
    assert project['qa'][0]['status'] == 'Complete'
    assert project['qa'][0]['reviewFingerprint']
    air_review = call('air-review', source)
    assert air_review.returncode == 0, air_review.stderr
    air_results = json.loads(air_review.stdout)
    assert len(air_results['conditions']) == 5 and len(air_results['processes']) == 2
    wet = next(row for row in air_results['conditions'] if row['record']['name']=='Fixture wet bulb')
    dew = next(row for row in air_results['conditions'] if row['record']['name']=='Fixture dew point')
    derived = next(row for row in air_results['conditions'] if row['record'].get('derivation'))
    assert wet['record']['humidityInput'] == {'kind':'wetBulbC','value':24}
    assert wet['state']['wetBulbC'] == 24
    assert wet['inputTrace']['unit'] == 'kg water/kg dry air'
    assert dew['record']['humidityInput']['kind'] == 'dewPointC'
    assert abs(dew['state']['dewPointC']-10) < 1e-7
    assert derived['inputTrace']['unit'] == 'derived RH fraction'
    assert air_results['processes'][1]['record']['firstConditionID'] == derived['record']['id']
    coil = air_results['processes'][1]['result']
    assert abs(coil['dryAirMassKgPerSecond'] - air_results['processes'][0]['result']['dryAirMassKgPerSecond']) < 1e-10
    assert coil['totalKW'] > 0 and abs(coil['totalKW'] - coil['sensibleKW'] - coil['latentKW']) < 1e-8
    assert coil['condensateKgPerHour'] > 0
    assert len(coil['traces']) == 5
    adp = coil['apparatusDewPoint']
    assert adp['method'].endswith('ADP v1') and len(adp['candidates']) > 0
    for candidate in adp['candidates']:
        assert 0 <= candidate['bypassFactorEnthalpy'] <= 1
        assert abs(candidate['humidityResidual']) <= 1e-10
        assert len(candidate['traces']) == 4
    envelope = call('envelope-review', source)
    assert envelope.returncode == 0, envelope.stderr
    assemblies = json.loads(envelope.stdout)['assemblies']
    assert len(assemblies) == 1
    assert abs(assemblies[0]['result']['uFactor'] - 0.0875) < 1e-12
    assert abs(assemblies[0]['result']['effectiveR'] - 80/7) < 1e-12
    assert len(assemblies[0]['result']['traces']) == 6
    assert assemblies[0]['record']['paths'][0]['layers'][0]['source'] == 'Synthetic only'
    room = call('room-review', source)
    assert room.returncode == 0, room.stderr
    room_review = json.loads(room.stdout)
    assert len(room_review['rooms']) == 2 and len(room_review['assemblies']) == 1
    transmission = room_review['rooms'][0]['result']
    assert abs(transmission['outwardLossBtuh'] - 787.5) < 1e-10
    assert abs(transmission['inwardGainBtuh'] - 87.5) < 1e-10
    assert abs(transmission['netOutwardBtuh'] - 700) < 1e-10
    assert transmission['surfaces'][0]['netOpaqueAreaSF'] == 150
    assert len(transmission['excludedComponents']) == 6
    unrated = transmission['openingTransmission']
    assert not unrated['allListedOpeningsRated']
    assert unrated.get('combinedEnvelopeLossBtuh') is None
    rated = room_review['rooms'][1]['result']['openingTransmission']
    assert rated['allListedOpeningsRated']
    assert abs(rated['knownOpeningLossBtuh'] - 1235) < 1e-10
    assert abs(rated['combinedEnvelopeLossBtuh'] - 2088.125) < 1e-10
    assert abs(rated['combinedEnvelopeNetOutwardBtuh'] - 2044.375) < 1e-10
    assert len(rated['traces']) == 5
    assert len(room_review['history']) == 1
    revision = room_review['history'][0]
    assert revision['before']['id'] == revision['after']['id'] == room_review['rooms'][1]['record']['id']
    assert revision['before']['indoorDesignF']['value'] == 70
    assert revision['after']['indoorDesignF']['value'] == 75
    assert len(revision['assemblyBasis']) == 1
    assert abs(revision['beforeResult']['openingTransmission']['combinedEnvelopeNetOutwardBtuh'] - 1840) < 1e-10
    assert abs(revision['afterResult']['openingTransmission']['combinedEnvelopeNetOutwardBtuh'] - 2044.375) < 1e-10
    before = source.read_bytes()
    stale_output = root / 'stale-revision-must-not-exist.json'
    stale = call('apply', source, '--request', stale_revision_request, '--output', stale_output)
    assert stale.returncode != 0 and not stale_output.exists() and source.read_bytes() == before
    rejected = call('apply', source, '--request', request_path, '--output', source)
    assert rejected.returncode != 0 and source.read_bytes() == before
    review = call('review', source)
    assert review.returncode == 0, review.stderr
    assert json.loads(review.stdout).get('releasableSellingPrice') is None
    assert hashlib.sha256(fixture.read_bytes()).hexdigest() == original_hash
print(json.dumps({'installedPlugin': str(args.plugin), 'operations': len(operations), 'originalUnchanged': True, 'overwriteRejected': True, 'staleEditRejected': True, 'reviewRemainsDraft': True}, indent=2))
