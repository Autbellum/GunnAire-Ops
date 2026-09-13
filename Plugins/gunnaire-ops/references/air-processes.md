# Air conditions and processes

Use the standard `apply` wrapper with `--request` and `--output` as described in project-edits.md. Always preserve the supplied unit basis. Native fields default to IP; these structured API fields use the explicit SI/CFM units below. A dry bulb of 75 °F must be converted, not sent as `dryBulbC:75`. RH is a fraction, never a percent. Pressure is absolute station pressure, never gauge or sea-level-corrected pressure. Do not infer project conditions from these fictional examples.

## Save a condition

The example uses the existing RH format. All shown keys are required for that format; alternatively replace `relativeHumidity` with the `humidityInput` object below. The returned `recordID` identifies the new condition.

```json
{
  "operation": "aircondition.create",
  "author": "Actual recorder name",
  "name": "Condition location and design case",
  "source": "Actual temperature, humidity and pressure sources / basis",
  "dryBulbC": 25,
  "relativeHumidity": 0.5,
  "pressurePa": 101325,
  "dryBulbClassification": "USER-PROVIDED",
  "humidityClassification": "USER-PROVIDED",
  "pressureClassification": "ENGINEERING-ASSUMPTION"
}
```

Classifications: EXTRACTED, USER-PROVIDED, CODE-DEFAULT, ENGINEERING-ASSUMPTION or RFI-REQUIRED. RFI-REQUIRED inputs must be resolved before saving a calculated condition. Always document actual sources; choosing CODE-DEFAULT does not verify a code or supply a default. Domain: −100 to 80 °C dry bulb, 0–1 RH, 20,000–120,000 Pa, and saturation pressure below total pressure. Exactly dry air has no finite dew point.

## Wet-bulb or dew/frost-point condition

Replace `relativeHumidity` with exactly one of these objects; never send both fields:

```json
"humidityInput": {"kind": "wetBulbC", "value": 24}
```

```json
"humidityInput": {"kind": "dewPointC", "value": 10}
```

A nested `relativeHumidity` kind is also accepted with a fraction in `value`. Kind values are exactly `relativeHumidity`, `wetBulbC`, or `dewPointC`; `value` must be numeric and the object must contain only `kind` and `value`. Every other required condition field remains the same. Temperatures are °C in this API, even though native input defaults to °F.

Wet bulb and dew/frost point must be at least −100 °C and no warmer than dry bulb. Impossible combinations that imply negative humidity are rejected. Wet bulb means thermodynamic wet bulb with ice balance below 0 °C and water balance at/above 0 °C; instrument-specific corrections are not modeled. Dew/frost point uses the existing saturation correlation. Preserve the actual source method and conditions; do not silently treat instrument measurements as corrected thermodynamic values.

Saved records retain `humidityInput` and derived RH. Validation rejects disagreement; legacy records without humidityInput remain RH-based. `air-review` includes an `inputTrace` for each condition in addition to its original record and computed state. New input modes do not supply jurisdiction, weather probabilities, coincidence or design-condition approval automatically.

## Save a process

All keys are required. Use existing condition identities, not names or invented IDs.

```json
{
  "operation": "airprocess.create",
  "author": "Actual recorder name",
  "name": "Coil and design case",
  "source": "Actual inlet airflow source and assumptions",
  "kind": "Cooling coil",
  "firstConditionID": "existing-inlet-condition-id",
  "secondConditionID": "existing-outlet-condition-id",
  "firstActualCFM": 1200,
  "secondActualCFM": null,
  "flowClassification": "USER-PROVIDED"
}
```

For `Mixed air`, both conditions are incoming streams and `secondActualCFM` must be a number. Both flows are actual CFM at their respective source conditions; zero for one stream is permitted, but total flow must be positive. For `Cooling coil`, first is inlet, second is outlet, firstActualCFM must be positive and secondActualCFM must be null. States must share pressure within 1 Pa. Heating/humidification, supersaturated mixtures and unsupported pressure-drop cases fail explicitly. Flow classification applies to both streams; the source text must identify each flow's actual basis.

## Read results

```sh
python3 scripts/loadsight.py air-review /absolute/project.json
```

Read-only JSON includes `conditions` (record metadata and recalculated state) and `processes` (record metadata and recalculated result). Mixed output includes state, dry-air mass flow, outlet actual CFM and traces. Cooling output includes totalKW, sensibleKW, latentKW, condensateKgPerHour, sensibleHeatRatio (absent/null when undefined), dryAirMassKgPerSecond and traces. Cooling results also include `apparatusDewPoint`: method, status, candidates and notes. Each candidate includes temperatureC, humidityRatio, three bypass factors (temperature/humidity/enthalpy), humidityResidual, nearTangent and its own traces. Multiple candidates are not a selected coil; unresolved or not-applicable statuses are not zero ADP. Each trace includes equation, substitution, unit and assumptions. Property fields carry SI units in their names; native UI converts power to Btuh and moisture removal to lb/h. Enthalpy absolute SI and IP datums differ and must not be mixed.

Saving appends source records and reopens QA; results are recomputed instead of trusting serialized output values. There is no automatic equipment selection, PE signoff, proposal release, code determination or Ops publication. Do not report these worksheets as a complete building load or full coil simulation. Use aircondition.derive to make a saved mixed output selectable by downstream processes without manual re-entry. It remains a calculated model state, not an observed condition. Read the workspace BUILD_STATUS.md and Reference/engineering/Air-process-method.md for verification and remaining work.

ADP is a supplemental geometric inference from the supplied process line and site pressure. Input conditions are never adjusted to force an intersection. Do not treat a modeled saturation point as measured coil surface temperature, or choose among multiple candidates without the actual engineering/manufacturer basis. Subfreezing results use the ice correlation without a frost/defrost model. The method is documented in the workspace Reference/engineering/Coil-ADP-method.md.

## Reuse a mixing output as a condition

```json
{
  "operation": "aircondition.derive",
  "author": "Actual recorder name",
  "name": "Mixed air at coil inlet",
  "source": "Actual downstream use / modeling basis",
  "processID": "existing-mixing-process-id"
}
```

All fields are required. The new recordID identifies a condition that can be used as firstConditionID or secondConditionID. No numeric overrides are accepted. The derived condition retains a process link, recursive upstream evidence fingerprint, exact computed state and full mixed-stream actualCFM under `derivation`. Use that CFM only when the downstream path carries the full stream; a split branch needs its own documented flow. Native controls provide an explicit button for copying the full-stream airflow.

Derived conditions are classified as engineering assumptions/model outputs and are explicitly labeled calculated. `air-review` includes derivation metadata and an input trace pointing back to the source mixing process. Shared graph validation checks dependencies before calculations, compares values/flow against recomputed output, and rejects cycles, missing sources or changed upstream evidence. Saving reopens QA. Prior records remain retained; new versions should be appended with new downstream references. This is recorded provenance, not authenticated identity or an automatic revision/recalculation workflow.
