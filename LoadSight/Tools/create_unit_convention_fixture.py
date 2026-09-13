#!/usr/bin/env python3
"""Reproducible synthetic PDF schedule; no customer/manufacturer/design data."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
labels = [(50,750,'SYNTHETIC EQUIPMENT SCHEDULE - REVIEW ONLY'),
          (50,700,'TAG'),(180,700,'COOL MBH'),(340,700,'CFM'),(450,700,'MCA'),
          (50,650,'RTU-1'),(180,650,'12'),(340,650,'1,200'),(450,650,'18'),
          (50,600,'EF-2'),(340,600,'250'),
          (50,550,'RTU-1'),(180,550,'30'),(340,550,'1,400'),(450,550,'20'),
          (50,450,'PLAN TAGS: RTU-1 EF-2 AHU-9'),
          (50,420,'LEGEND: MBH = 1000 BTU_IT/H'),
          (50,400,'BTU denotes International Table units.')]
stream = '\n'.join(f'BT /F1 12 Tf 1 0 0 1 {x} {y} Tm ({t}) Tj ET' for x,y,t in labels).encode('ascii')
objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
           b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
           b'<< /Length '+str(len(stream)).encode()+b' >>\nstream\n'+stream+b'\nendstream']
data=bytearray(b'%PDF-1.4\n'); offsets=[0]
for index,obj in enumerate(objects,1):
    offsets.append(len(data)); data.extend(f'{index} 0 obj\n'.encode()+obj+b'\nendobj\n')
xref=len(data);data.extend(f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode())
for offset in offsets[1:]: data.extend(f'{offset:010} 00000 n \n'.encode())
data.extend(f'trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
folder=root/'Tests/LoadSightKitTests/Fixtures';(folder/'UnitConventionSchedule.pdf').write_bytes(data)
sha=hashlib.sha256(data).hexdigest()
request={'schemaVersion':1,'regions':[{'sourceID':sha,'pageID':sha+':1','bodyBounds':{'x':40,'y':520,'width':480,'height':160},'columns':[
    {'field':'tag','minX':40,'maxX':160,'headerText':'TAG'},
    {'field':'coolingTotal','minX':160,'maxX':320,'headerText':'COOL MBH','unitText':'MBH'},
    {'field':'airflow','minX':320,'maxX':430,'headerText':'CFM','unitText':'CFM'},
    {'field':'minimumCircuitAmpacity','minX':430,'maxX':520,'headerText':'MCA'}],
    'textMode':'nativePDFWords','recordedBy':'Synthetic fixture author','mappingBasis':'Controlled fixture header positions; not customer or engineering evidence.'}]}
(folder/'UnitConventionScheduleMapping.json').write_text(json.dumps(request,indent=2)+'\n')
print(sha)
