# Schedule scalar unit interpretation

Method: `Explicit scalar schedule units v2`, implemented in `Sources/LoadSightIngest/ScheduleNumericInterpretation.swift`.

This is an unreviewed arithmetic interpretation of a literal schedule cell. It neither changes original text/evidence nor promotes a row into physical equipment, an approved engineering input or a reviewed quantity. Extraction returns `numericReview` records keyed by the unchanged source-bound row ID. The native cell view uses the same interpreter.

## Parsing contract

Only a finite signed decimal scalar is accepted, with a decimal point and optional strict three-digit comma grouping. A comma is interpreted as a thousands separator, not a locale decimal separator; verify the source convention. Ranges, slash-separated ratings, suffix units, footnotes, OCR substitutions and scientific notation stay unresolved. Input length is limited to 128 characters. No unit comes from the field name or a guessed header. Missing text is `missing`; unsupported/ambiguous numeric content is `unresolved`; text fields are `notNumeric`. Unresolved results omit values and conversion factors.

Quantities require an explicit each/count unit and an exactly representable nonnegative integer; they remain schedule quantities. Supported phase values are 1 and 3 with an explicit phase unit. Other non-temperature scalar fields reject negative values. Temperatures reject values below absolute zero in their input scale; conversion rounding at the absolute-zero boundary is clamped to −273.15 °C. These domain checks are not equipment plausibility or code-compliance checks.

## Supported units

Spaces surrounding or inside recorded units are ignored for alias matching. Case remains significant except for listed alternatives.

| Fields | Input aliases | Output and operation |
| --- | --- | --- |
| Airflow, outdoor air, water flow | CFM, cfm, ft3/min, ft³/min | m³/s: × 0.028316846592 / 60 |
| Same | L/s, l/s; m3/s, m³/s; m3/h, m³/h | m³/s: × 0.001; × 1; ÷ 3600 respectively |
| Same | USGPM, USgal/min | m³/s: × 0.003785411784 / 60 |
| Cooling, heating, furnace input/output | W, kW, MW | W: × 1, 1000, 1000000 respectively |
| Same | Btu_IT/h, BTU_IT/HR | W: × 1055.05585262 / 3600 |
| Same | tonofrefrigeration, tonR | W: × 12000 × 1055.05585262 / 3600 |
| External static pressure | Pa, kPa | Pa: × 1 or 1000 |
| Entering/leaving water temperature | F, °F; C, °C; K | °C: (value − 32) × 5/9; identity; value − 273.15 |
| Weight | lb, lbs, lbm; kg | kg: × 0.45359237; identity |
| Voltage | V, volt, volts | V: identity |
| MCA/MOP | A, amp, amps | A: identity |
| Quantity | each, EA, ea, count | each: integer identity |
| Phase | phase, ph, Ø | phase: integer identity |

Factors use the international foot, US liquid gallon, avoirdupois pound and explicitly named International Table Btu. The conversion relationships are sourced from [NIST SP 811 Appendix B.8](https://www.nist.gov/pml/special-publication-811/nist-guide-si-appendix-b-conversion-factors/nist-guide-si-appendix-b8) and its [footnotes](https://www.nist.gov/pml/special-publication-811/nist-guide-si-footnotes), checked 2026-09-10. This implementation derives flow rates from volume/time relationships rather than shortening the factors to the printed table precision.

Bare GPM, MBH, Btu/h and tons remain unresolved unless a compatible source-defined convention is recorded as described below. Water-column pressure remains unresolved. Do not alter the literal source header to force conversion. Dimensions, sound levels, mixed units and other aliases remain literal. Recognition confidence, partial-row warnings and source-boundary uncertainty remain applicable even when scalar arithmetic succeeds.

## Verification

Shared tests cover reference conversions, affine temperature offsets including absolute zero, zero versus missing, malformed number formats, SI case distinction, field/unit compatibility, domain holds, and original-PDF extraction/JSON output with unchanged literal rows. Native and plugin verification is recorded in [schedule numeric review](../verification/Schedule-numeric-review.md).

## Subsequent dimension support

Separate ordered dimension interpretation is now available; see [dimension method and verification](../verification/Schedule-dimensions.md). The scalar contract above continues to treat dimensions separately from a single numeric scalar.

## Sourced convention extension (v2)

Optional column definitions record the convention and nonblank source citation separately from literal unit text. Five definitions cover International Table Btu/h, thousands of International Table Btu/h, refrigeration tons, US liquid GPM and Imperial GPM. Definitions are restricted to matching aliases and compatible scalar fields; there is no default selection. Exact contract and aliases: [plugin schedule reference](../../../Plugins/gunnaire-ops/references/equipment-schedules.md#source-defined-unit-conventions).

Thousands of Btu IT/h use 1000 × 1055.05585262 / 3600 W. Imperial GPM uses 0.00454609 / 60 m³/s; US liquid GPM retains 0.003785411784 / 60. The Imperial gallon and refrigeration-ton relationships are confirmed in [NIST SP 811 B.9](https://www.nist.gov/pml/special-publication-811/nist-guide-si-appendix-b-conversion-factors/nist-guide-si-appendix-b9), checked 2026-09-10. NIST supports conversion relationships; the drawing/specification must establish the abbreviation's actual meaning.

Changing a definition or its source citation changes source-row identity. Original text, unit labels and evidence remain intact. Map history captures before/after definitions. Missing text still has no value. A recorded citation is not machine-verified source interpretation or authenticated engineering approval. Water-column reference conditions, automatic legend detection and approved equipment association remain unfinished.

The sourced-definition model, native disk-reopen interaction and real-plugin evidence are recorded in [unit convention verification](../verification/Schedule-unit-conventions.md).
