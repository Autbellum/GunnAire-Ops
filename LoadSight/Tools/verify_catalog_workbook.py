#!/usr/bin/env python3
"""Read-only verification of a native workbook against its project source. Uses standard-library ZIP/XML."""
import json
from pathlib import Path
import sys
import zipfile
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

project_path, workbook_path = map(Path, sys.argv[1:3])
p = json.loads(project_path.read_text())
ns = {'x': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
with zipfile.ZipFile(workbook_path) as z:
    assert z.testzip() is None
    sheets = ET.fromstring(z.read('xl/workbook.xml')).findall('x:sheets/x:sheet', ns)
    assert [s.attrib['name'] for s in sheets] == ['Takeoff', 'RFIs', 'Review', 'Material costs', 'Catalog history']
    docs = [ET.fromstring(z.read(f'xl/worksheets/sheet{i}.xml')) for i in range(1,6)]
    def cell(doc, address):
        c = doc.find(f'.//x:c[@r="{address}"]', ns)
        if c is None: return None
        text = c.find('x:is/x:t', ns)
        if text is not None: return text.text or ''
        value = c.find('x:v', ns)
        return float(value.text) if value is not None else None
    for doc in docs:
        assert not doc.findall('.//x:f', ns), 'Export snapshots must not introduce executable source formulas'
        pane = doc.find('x:sheetViews/x:sheetView/x:pane', ns)
        assert pane.attrib['state']=='frozen' and pane.attrib['ySplit']=='5'
        assert doc.find('x:autoFilter', ns) is not None
    # Existing takeoff columns still carry the original row facts.
    for index, item in enumerate(p['items'],6):
        for col,key in [('A','id'),('B','description'),('C','quantity'),('D','unit'),('E','lifecycle'),('F','scope')]:
            assert cell(docs[0],f'{col}{index}') == item.get(key)
        assert cell(docs[3],f'A{index}') == item['id']
        assert cell(docs[3],f'E{index}') == item.get('materialUnit')
        m=item.get('catalogMaterialMapping')
        events=[e for e in p.get('catalogMaterialHistory',[]) if e['itemID']==item['id']]
        if m:
            amount=m['catalog'].get('purchaseCost')
            converted=None if amount is None else amount*m['catalogUnitsPerTakeoffUnit']
            assert cell(docs[3],f'G{index}') == converted
            matches=converted==item.get('materialUnit') and all(m[k]==item.get(v,'') for k,v in [('takeoffUnit','unit'),('itemDescription','description'),('lifecycle','lifecycle')])
            assert cell(docs[3],f'F{index}') == ('Current' if matches else 'Stale')
        else:
            assert cell(docs[3],f'F{index}') == ('Removed link' if events else 'Unmapped')
            assert cell(docs[3],f'G{index}') is None
        assert cell(docs[3],f'I{index}') == (events[-1]['id'].upper() if events else None)
    groups={}
    for row in docs[4].findall('x:sheetData/x:row', ns):
        i=int(row.attrib['r'])
        if i<6:continue
        revision=cell(docs[4],f'B{i}');groups.setdefault(revision,[]).append(i)
    events=p.get('catalogMaterialHistory',[])
    assert set(groups)=={e['id'].upper() for e in events}
    for event in events:
        rows=groups[event['id'].upper()]
        by_field={cell(docs[4],f'F{i}'):i for i in rows}
        assert len(by_field)==len(rows)
        for i in rows:
            assert cell(docs[4],f'A{i}')==event['itemID']
            assert cell(docs[4],f'C{i}')==event['author']
            assert cell(docs[4],f'E{i}')==event['reason']
            expected=datetime.fromisoformat(event['recordedAt'].replace('Z','+00:00')).timestamp()/86400+25569
            assert abs(cell(docs[4],f'D{i}')-expected)<1e-9
        i=by_field['Recorded material cost (USD/unit)']
        assert cell(docs[4],f'G{i}')==event['beforeMaterialUnit']
        assert cell(docs[4],f'H{i}')==event['afterMaterialUnit']
        for col,side in [('G','before'),('H','after')]:
            mapping=event[side]
            if mapping:
                for label,path in [('Catalog item ID',['catalog','id']),('Catalog source',['catalog','source']),('Supplier',['catalog','supplier']),('Purchase cost (USD/purchase unit)',['catalog','purchaseCost']),('Purchase units per takeoff unit',['catalogUnitsPerTakeoffUnit']),('Compatibility / conversion evidence',['basis'])]:
                    value=mapping
                    for key in path:value=value.get(key)
                    assert cell(docs[4],f'{col}{by_field[label]}')==value
                if mapping.get('quote'):
                    for field,value in mapping['quote'].items():
                        label='quote.'+field
                        assert label in by_field, 'Missing quote history field: '+field
                        assert cell(docs[4],f'{col}{by_field[label]}')==value

    print(json.dumps(dict(status='passed',sheets=5,items=len(p['items']),revisions=len(events),historyRows=sum(map(len,groups.values())),checks=['typed costs and dates','null versus zero','stale basis','removed and unmapped links','source/revision reconciliation','existing takeoff facts','no formulas','filters and frozen headers']),indent=2))
