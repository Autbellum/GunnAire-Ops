#!/usr/bin/env python3
"""Verify the actual controlled iPad unit-convention package and plugin handoff."""
from pathlib import Path
import base64
import hashlib
import json
import subprocess
import sys

package, plugin, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=False)
project = json.loads((package/'project.json').read_text())
records = json.loads((package/'drawings.json').read_text())
assert len(records) == 1
record = records[0]; data = (package/'drawings'/record['id']).read_bytes()
workspace = Path(__file__).resolve().parents[1]
expected = workspace/'Tests/LoadSightKitTests/Fixtures/UnitConventionSchedule.pdf'
assert data == expected.read_bytes() and hashlib.sha256(data).hexdigest() == record['id']
assert project['items'] == [] and all(g['status'] == 'Open' for g in project['qa'])
assert len(project['scheduleMaps']) == 1 and len(project['scheduleMapHistory']) == 2
saved = project['scheduleMaps'][0]
column = saved['request']['regions'][0]['columns'][1]
citation = 'Page 1 legend: MBH = 1000 BTU_IT/H; BTU denotes International Table units.'
assert column['unitText'] == 'MBH'
assert column['unitDefinition'] == dict(convention='thousandBtuInternationalTablePerHour', source=citation)
history = project['scheduleMapHistory'][1]
assert history['after'] == project['scheduleMaps']
assert history['author'] == 'Synthetic checker'
assert history['before'][0]['request']['regions'][0]['columns'][1].get('unitDefinition') is None
# Reconstitute a portable fixture from the actual native package; the engine validates it again.
project['nativeDrawings'] = dict(schemaVersion=1, records=records, files={record['id']: base64.b64encode(data).decode()})
portable = output/'native-project.json'; portable.write_text(json.dumps(project, indent=2))
command = [sys.executable, str(plugin/'scripts/loadsight.py'), 'schedule-saved', str(portable),
           '--map-id', saved['id'], '--workspace', str(workspace)]
result = subprocess.run(command, capture_output=True, text=True)
(output/'stderr.log').write_text(result.stderr)
assert result.returncode == 0, result.stderr
review = json.loads(result.stdout); (output/'review.json').write_text(json.dumps(review, indent=2))
assert review['rows'][0]['cells'][1]['unitDefinition']['source'] == citation
assert abs(review['numericReview'][0]['cells'][1]['value'] - 3516.852842066667) < 1e-9
summary = dict(nativePackage=str(package), originalPDFUnchanged=True,
               sourceDefinitionAndHistoryRetained=True, takeoffStillEmpty=True, pluginReadsNativeMap=True)
(output/'summary.json').write_text(json.dumps(summary, indent=2)); print(json.dumps(summary))
