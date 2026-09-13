# Mixed-air and air-side cooling process method v1

This method extends the moist-air state worksheet described in Psychrometric-method.md. It does not replace a building load model or manufacturer equipment selection. Native UI: Calculations → Air processes. Plugin: `aircondition.create`, `airprocess.create`, then `air-review` through the local wrapper.

## Source basis and conventions

Adiabatic mixing conserves dry-air flow, water-vapor flow and moist-air enthalpy. The mass-weighted enthalpy/humidity approach is also visible in the primary [EnergyPlus MixedAir.cc implementation](https://github.com/NREL/EnergyPlus/blob/develop/src/EnergyPlus/MixedAir.cc). Unlike its subsequent saturation adjustment, this first LoadSight process method explicitly rejects fog-producing mixtures pending a liquid-water balance implementation.

The sensible/latent component split follows the minimum-humidity-ratio convention documented in primary [EnergyPlus Psychrometrics.hh](https://github.com/NREL/EnergyPlus/blob/develop/src/EnergyPlus/Psychrometrics.hh), functions PsyDeltaHSenFnTdb2Tdb1W and PsyDeltaHSenFnTdb2W2Tdb1W1. LoadSight retains its existing PsychroLib/ASHRAE property coefficients (1.006 and 1.86), not the different EnergyPlus coefficients. This is a convention cross-check, not numerical equivalence to an EnergyPlus coil simulation.

Primary source files inspected 2026-09-10: MixedAir.cc SHA-256 `bae0e719f24bd1c22752c1488e5b985d14b2539153446625d9255db51bb1fcb6`; Psychrometrics.hh SHA-256 `036a7692a4f93bf48225d2b9bd05089a02fdc7d7fd22e17e792a596dcb5681a2`. Underlying state/property references and retained MIT source are in the companion method document.

## Mixing

Each flow is **actual CFM at that inlet condition**, not standard CFM. Convert V to m³/s using 0.0004719474432, then dry-air mass rate m = V/v, where v is m³/kg dry air. Do not use total moist-air density with dry-air-basis enthalpy. The two conditions must share absolute pressure within 1 Pa.

For f = m1/(m1+m2):

- Wmix = f W1 + (1−f) W2.
- hmix = f h1 + (1−f) h2, using one consistent SI enthalpy datum.
- Tmix = (hmix−2501 Wmix)/(1.006+1.86 Wmix), °C.
- Outlet actual CFM = (m1+m2) vmix / 0.0004719474432.

Reconstruct RH from W and pressure using the existing saturation correlation. RH above 1 (except 1e−12 numerical tolerance) fails with an explicit fog/condensation message. No water removal is invented. Zero flow in one stream is allowed; zero total, negative/nonfinite flow and overflow fail. The method assumes adiabatic mixing, no fan heat and no leakage. The selected input conditions may be the same record; that is an identity blend.

## Cooling coil

First condition is inlet, second is outlet; airflow is actual inlet CFM. Outlet dry bulb and W must not exceed inlet values (W allows 1e−12 roundoff tolerance). Pressure-drop and heating/humidification models are separate.

Using dry-air mass flow m from inlet volume:

- Qt = m (hin−hout), kW; positive means air-side heat removal.
- Qs = m (1.006+1.86 Wout)(Tin−Tout), kW.
- Ql = Qt−Qs, kW. Algebraically the latent leg is m(2501+1.86 Tin)(Win−Wout).
- Water removed = 3600 m(Win−Wout), kg/h.
- SHR = Qs/Qt; undefined at zero load, never silently zero. Equal inlet/outlet conditions yield zero load.

Sensible/latent reconciliation uses the stated two-leg convention; different conventions may assign a small moisture/temperature cross term differently. This is air-side enthalpy decrease. It excludes the liquid condensate enthalpy leaving the control volume, fan heat, casing losses, leakage and refrigerant/chilled-water performance. It is not net refrigerant duty or a capacity selection. Power display uses 3412.141633 Btuh/kW, not an absolute-enthalpy datum conversion.

## Persistence and validation

Records append with name, source/basis, author, date, kind, method version, referenced condition IDs, actual CFM inputs and flow classification. One flow classification applies to all flows; source text must describe each flow's basis. RFI-required flows cannot be saved as calculated results. Cooling requires secondActualCFM null; mixing requires a number. Results are recomputed from input states; decoded derived enthalpy or specific-volume fields are never trusted. Shared portable/native project validation rejects missing references, duplicate identities and unsupported methods. Saving reopens QA and retains prior source records. This is recorded provenance, not authenticated identity.

Saved mixing outputs can now be explicitly derived into reusable conditions with upstream fingerprints and dependency validation; see Air-network-method.md. Automatic revision propagation, recovery and complete network flow/pressure solving remain unfinished. Supplemental ADP/bypass analysis is now documented in Coil-ADP-method.md. Flow/network sizing, fan/pressure-loss models, fog mass balance, heating/humidification, design-day models and equipment selection remain unfinished.

## Evidence

74 XCTest tests pass. Six new process tests cover:

1. Mixing with a 1:3 dry-air mass split: Wmix=0.0125, hmix=63.45795 kJ/kg, and moisture/enthalpy/outlet-flow closure.
2. A 1 kg dry-air/s coil from 30 °C/W=0.014 to 15 °C/W=0.009: Qt=28.1251 kW, Qs=15.3411 kW, Ql=12.784 kW, water=18 kg/h; plus dry-coil and zero-load cases.
3. Invalid pressure, zero total flow, reverse/heating condition, nonfinite airflow and fog rejection; single-stream identity.
4. Recomputed canonical properties despite forged decoded enthalpy/specific volume.
5. Strict structured-request numeric/classification handling and returned identities.
6. Native package round trip, source preservation, QA reopening and missing-reference rejection.

These are analytical balance checks and implementation tests, not full independent field validation. The installed plugin passed a 13-operation temporary-fixture workflow including condition creation, mixing, cooling and read-only traces; source preservation/no-overwrite/draft status checks passed. Mac/iOS builds pass; native interaction remains unverified due to the previously observed unavailable computer-use connection.
