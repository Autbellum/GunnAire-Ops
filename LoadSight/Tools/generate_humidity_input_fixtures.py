"""Reference outputs for source wet-bulb/dew-point inputs, using retained PsychroLib."""
import hashlib, importlib.util, json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
source = root/'Reference/engineering/psychrolib_reference.py'
spec = importlib.util.spec_from_file_location('psychro_reference',source)
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p); p.SetUnitSystem(p.SI)
rows=[]
for t in [-30,-5,5,25,40,60]:
 for pressure in [65000,101325]:
  for rh in [.3,.8]:
   wet=p.GetTWetBulbFromRelHum(t,rh,pressure)
   dew=p.GetTDewPointFromRelHum(t,rh)
   for kind,value in [('wetBulbC',wet),('dewPointC',dew)]:
    w=p.GetHumRatioFromTWetBulb(t,value,pressure) if kind=='wetBulbC' else p.GetHumRatioFromTDewPoint(value,pressure)
    rows.append(dict(t=t,p=pressure,kind=kind,value=value,w=w,rh=p.GetRelHumFromHumRatio(t,w,pressure)))
for value in [-0.001,0,0.01,0.010001]:
 for kind in ['wetBulbC','dewPointC']:
  t,pressure=5,101325
  w=p.GetHumRatioFromTWetBulb(t,value,pressure) if kind=='wetBulbC' else p.GetHumRatioFromTDewPoint(value,pressure)
  rows.append(dict(t=t,p=pressure,kind=kind,value=value,w=w,rh=p.GetRelHumFromHumRatio(t,w,pressure)))
(root/'Tests/LoadSightKitTests/Fixtures/HumidityInputs.json').write_text(json.dumps(dict(source='PsychroLib 2.5.0 SI input conversions',sha256=hashlib.sha256(source.read_bytes()).hexdigest(),rows=rows),indent=2)+'\n')
print(len(rows),'reference input states generated')
