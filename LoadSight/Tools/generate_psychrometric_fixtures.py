"""Generate reference values from the retained upstream implementation, not Swift code."""
import importlib.util, json, hashlib
from pathlib import Path
root = Path(__file__).resolve().parents[1]
source = root / 'Reference/engineering/psychrolib_reference.py'
spec = importlib.util.spec_from_file_location('psychro_reference', source)
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
p.SetUnitSystem(p.SI)
rows = []
for t in [-40, -10, -0.01, 0, 0.01, 0.02, 10, 25, 40, 60]:
    for rh in [.1, .5, .9, 1]:
        for pressure in [65000, 85000, 101325, 120000]:
            w, wet, dew, pv, h, v, _ = p.CalcPsychrometricsFromRelHum(t, rh, pressure)
            p.SetUnitSystem(p.IP)
            hip = p.GetMoistAirEnthalpy(t * 1.8 + 32, w)
            p.SetUnitSystem(p.SI)
            rows.append(dict(t=t,rh=rh,p=pressure,w=w,wet=wet,dew=dew,pv=pv,h=h/1000,v=v,hip=hip))
out = dict(source='PsychroLib 2.5.0 upstream SI', sha256=hashlib.sha256(source.read_bytes()).hexdigest(), rows=rows)
(root/'Tests/LoadSightKitTests/Fixtures/PsychrometricStates.json').write_text(json.dumps(out,indent=2)+'\n')
print(len(rows), 'reference states generated')
