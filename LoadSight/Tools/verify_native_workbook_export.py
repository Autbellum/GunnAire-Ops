#!/usr/bin/env python3
"""Read-only check of the workbook saved by WorkbookExportUITests' synthetic app."""
import hashlib
import json
from pathlib import Path
import sys
import zipfile
import xml.etree.ElementTree as ET

path = Path(sys.argv[1])
ns = {'x': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
with zipfile.ZipFile(path) as z:
    assert z.testzip() is None
    sheets = ET.fromstring(z.read('xl/workbook.xml')).findall('x:sheets/x:sheet', ns)
    assert [s.attrib['name'] for s in sheets] == ['Takeoff', 'RFIs', 'Review', 'Material costs', 'Catalog history']
    def cell(sheet, address):
        doc = ET.fromstring(z.read(f'xl/worksheets/sheet{sheet}.xml'))
        c = doc.find(f'.//x:c[@r="{address}"]', ns)
        t = c.find('x:is/x:t', ns)
        return t.text if t is not None else float(c.find('x:v', ns).text)
    assert cell(1, 'A6') == 'CMP-1' and cell(1, 'C6') == 10 and cell(1, 'D6') == 'LF'
    assert cell(4, 'E6') == 10 and cell(4, 'F6') == 'Current' and cell(4, 'G6') == 10
    history = z.read('xl/worksheets/sheet5.xml').decode()
    assert 'Synthetic comparison catalog' in history and 'Synthetic original conversion' in history
print(json.dumps({'status': 'passed', 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'tabs': 5, 'quantityLF': 10, 'materialUnitUSD': 10, 'mappingHistoryPreserved': True}))
