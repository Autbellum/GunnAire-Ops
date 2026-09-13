# Supplemental coil ADP and bypass-factor method v1

## Basis and applicability

The requested engineering scope explicitly includes apparatus dew point (ADP). This implementation supplements the existing air-side cooling load; it does not change that load or adjust supplied entering/leaving conditions.

The saturation/process-line approach and enthalpy bypass-factor relationship are documented in the primary [EnergyPlus DXCoils.cc CalcCBF implementation](https://github.com/NatLabRockies/EnergyPlus/blob/develop/src/EnergyPlus/DXCoils.cc). That routine was inspected on 2026-09-10; source SHA-256 `cf56cd3833821b1b387d92c4f584b2a0289ee01afe5dd8b6e777608fb8bcd5b9`. Its rated calculation uses standard pressure. LoadSight instead uses the explicitly supplied common site pressure and its retained PsychroLib/ASHRAE saturation/enthalpy coefficients. The root solver is implemented locally; this is not a claim of numerical equivalence to the complete EnergyPlus rated-coil model.

Inputs must be valid moist-air states at the same pressure (within 1 Pa), with no entering-to-leaving increase in dry bulb or humidity ratio. Public analysis recomputes properties from each state's primary inputs. Dry/sensible-only or effectively zero-temperature-change cases return **Not applicable**, not zero ADP. Thresholds are ΔT > 1e−8 °C and ΔW > 1e−12 kg/kg for the wet-coil inference.

## Equations

Let m = (Win−Wout)/(Tin−Tout). The extrapolated straight process line in T/W coordinates is:

`Wline(T) = Win − m(Tin−T)`.

Find T at/below the leaving dry bulb such that:

`Wsat(T,Psite) − Wline(T) = 0`.

For each resolved candidate:

- BFt = (Tout−Tadp)/(Tin−Tadp).
- BFw = (Wout−Wadp)/(Win−Wadp).
- BFh = (hout−hadp)/(hin−hadp), using the same SI enthalpy datum throughout.

Temperature and humidity factors should agree for the line model. Enthalpy includes a temperature/humidity cross term; BFh need not be identical. All three factors are reported, with equations and substitutions. No unsupported engineering acceptance threshold for BFh agreement is supplied.

## Root and candidate checks

The search range is −100 °C to leaving dry bulb. Saturated W is convex over each supported ice/water correlation branch. The solver searches each branch separately, locating the residual minimum with 100 golden-section steps, then bisecting sign-changing monotone halves with 80 iterations. It handles near tangency explicitly instead of relying on a coarse sampling grid. The saturation branch split is 0.01 °C, using the existing state method's triple-point convention.

Candidate acceptance requires finite bypass factors within [0,1] allowing 1e−9 rounding slack, absolute humidity residual ≤1e−10 kg/kg, and |BFt−BFw|≤1e−6. Only rounding-level factor excursions are clamped. Root identities within 1e−5 °C are deduplicated. A residual minimum within 1e−12 kg/kg is marked near-tangent; such a result is numerically sensitive and requires input-precision review. These are solver tolerances, not measurement uncertainty claims.

Candidates are sorted warmest first. Multiple valid intersections return **Multiple model intersections**, with no automatic selection of a physical coil. A single candidate returns **One model intersection**. No accepted candidate returns **No resolved model intersection**, preserving the original inlet/outlet state and air-side load. Subfreezing candidates explicitly note that frost/defrost and surface physics are not modeled. ADP is an equivalent saturation-state model, not a measured coil surface temperature.

## Native and plugin behavior

Native: Calculations → Air processes → Cooling coil → Apparatus dew point and bypass factors. Status, interpretation notes, all candidates, factors and candidate traces are visible.

Plugin: `air-review` returns a supplemental `apparatusDewPoint` object within each cooling result, with `method`, `status`, `candidates` and `notes`. Existing saved air-process inputs and the base air-side load method remain intact. The ADP object has its own method identifier; it is supplemental inference, not a reviewer approval. The optional field permits decoding older serialized cooling results, while current reviews recompute from source inputs. Installed plugin reference documentation describes the new output.

## Verification and remaining scope

78 XCTest tests pass. Four new tests cover:

- 60 constructed cases across 85/101.325/120 kPa, ADP −10/0/5/10/20 °C and bypass factors 0/0.1/0.5/0.9. Each line is built through a known saturation point; expected ADP and BF are specified before calling the solver. Checks include temperature, humidity, residual and physical BF range.
- Dry/zero-change, reverse/heating and no-intersection cases.
- Near-tangent and multiple-root status, including a known warmest ADP at 10 °C.
- Supplemental JSON output without changing the previously verified 28.1251 kW analytical cooling load or five base traces.

This establishes analytic-case and implementation evidence. It does not establish full physical coil validation, manufacturer approval, field accuracy, moisture/frost dynamics or complete load-method certification. The remaining engineering scope includes published/manufacturer benchmarks, model uncertainty, capacity curves, process graphs, room/zone/system loads, and heating/humidification/fog models. Native interactive acceptance remains unverified because computer use again returned `Sky Computer Use native pipe closed before response` during this pass.
