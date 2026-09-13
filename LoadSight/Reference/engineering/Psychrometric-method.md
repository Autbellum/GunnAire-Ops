# Moist-air state method v1

## Provenance

Equations and coefficients are adapted from the MIT-licensed [PsychroLib 2.5.0 source](https://psychrometrics.github.io/psychrolib/_modules/psychrolib.html), which identifies ASHRAE 2017 Fundamentals chapter 1 equations 5–6, 22, 26, 30, 33, 35 and 36. This records the implemented equation basis, not a claim of conformance to the latest complete Handbook or ACCA methods.

Retained reference implementation: `psychrolib_reference.py`, fetched 2026-09-10 from https://raw.githubusercontent.com/psychrometrics/psychrolib/master/src/python/psychrolib/__init__.py . SHA-256: `37e08506bdc2e652a77026e7107ece7eaabb1c40997b563b88fe2951385aefdf`. Full MIT notice is in `PsychroLib-LICENSE.txt` and exposed in the native method section. Python is only used for fixture generation; the native app runs Swift.

## Inputs, units and limits

SDK inputs are dry bulb in °C, RH as fraction [0,1], and absolute station pressure in Pa. Native UI defaults to °F, RH percent and psia. Conversion: °C = (°F − 32)/1.8; Pa = psia × 6894.757293168. Nothing defaults to a presumed site condition. Each saved input is classified as extracted, user-provided, code-default, engineering-assumption or RFI-required; unresolved RFI-required states cannot be calculated/saved through the native flow. Author, source/basis, timestamp, method version and assumptions log are retained with inputs.

Air-state domain is −100 to 80 °C and 20–120 kPa, additionally requiring saturation pressure at dry bulb to be below total pressure. Saturation-pressure helper supports −100 to 200 °C. Nonfinite/out-of-domain values are rejected. This is a bounded ideal-gas engineering worksheet, not a universal fluid-property solver.

## Equations

- Saturation pressure uses separate ASHRAE log-pressure polynomial correlations over ice and water, switching at the 0.01 °C triple point. Exact coefficients are visible in `Sources/LoadSightCalc/Psychrometrics.swift`.
- Pv = RH × Pws(T).
- W = 0.621945 × Pv / (P − Pv), on a dry-air mass basis.
- h(SI) = 1.006 × T°C + W × (2501 + 1.86 × T°C), kJ/kg dry air, SI 0 °C datum.
- h(IP) = 0.240 × T°F + W × (1061 + 0.444 × T°F), Btu/lb dry air, IP 0 °F datum. This is independently evaluated using the IP empirical coefficients; absolute enthalpy is not obtained by multiplying SI h by a conversion factor. The datums must not be mixed.
- v = 287.042 × (T°C + 273.15) × (1 + 1.607858 × W) / P, m³/kg dry air. IP display multiplies by 16.018463 to ft³/lb dry air.
- Dry-air mass density = 1/v; total moist-air density = (1+W)/v.
- Dew/frost point inverts Pws with 80 bounded bisection steps. Exactly dry air has W=0 and no finite dew point. A dew point below the lower correlation limit remains unavailable with a note, not a fabricated −100 °C value.
- Thermodynamic wet bulb solves the moist-air balance with the ASHRAE liquid-water branch at/above 0 °C and ice branch below. The computed W residual must be less than 1e−8; unresolved roots at the range/phase boundary return unavailable with an explanatory note. No reference-library minimum humidity clamp is copied. Saturated input returns dry bulb exactly for both dew and wet bulb.

The native details show equations, substitutions and units. Saved records store inputs rather than trusting serialized calculated values; the SDK recomputes results and rejects unrecognized methods. Saving appends a condition and reopens QA; prior source records remain retained. This is recorded provenance, not authenticated author identity.

## Verification and remaining scope

`Tools/generate_psychrometric_fixtures.py` creates 160 states using the retained upstream Python implementation, covering −40 to 60 °C, 10/50/90/100% RH, and 65/85/101.325/120 kPa. Swift compares humidity ratio, vapor pressure, SI/IP enthalpy, volume, dew/frost and wet-bulb values. Temperature agreement tolerance is 0.002 °C to account for the upstream solver tolerance. Separate checks cover exactly dry air, saturation, pressure dependence, invalid inputs, unresolved input classification, unsupported saved methods, QA reopening and native package round trips.

This comparison tests implementation parity against the retained reference; it is not an independent validation of the underlying empirical equations or a full psychrometric-method certification. Native screen interaction remains unverified because the computer-use connection is unavailable.

Air mixing, air-side cooling, supplemental ADP/bypass analysis and CLI/plugin exposure have since been added; see Air-process-method.md and Coil-ADP-method.md. Wet-bulb and dew/frost-point input modes have since been added; see Humidity-input-method.md. Still required: complete coil physics/performance, independent published-property benchmarks, room/zone/system load integration, design-weather selection and project assumption management/editing. No equipment selection, adopted-code determination or full Manual J/N load result is produced here.
