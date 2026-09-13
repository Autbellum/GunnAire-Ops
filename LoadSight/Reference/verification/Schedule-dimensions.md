# Ordered schedule dimensions — 2026-09-10

The shared extractor now supplies `dimensionReview` keyed by unchanged row IDs. Literal cell text and header units remain intact. Native review shows converted lengths alongside the original dimensions, with the interpretation basis available in a disclosure.

## Method

`Explicit schedule dimension sequence v1` accepts two or three positive finite decimal components separated by `x`, `X` or `×`. An explicit common header unit is required. Supported aliases are in/inch/inches/double quote, ft/foot/feet/apostrophe, mm, cm and m. Case is significant. Conversion factors to metres are 0.0254, 0.3048, 0.001, 0.01 and 1 respectively, using the international foot and [NIST SP 811 length relationships](https://www.nist.gov/pml/special-publication-811/nist-guide-si-appendix-b-conversion-factors/nist-guide-si-appendix-b8).

The output preserves component order and does not name width, height or depth. Orientation, clearance versus equipment size, source mapping and recognition remain unconfirmed. No area, volume, physical geometry or takeoff quantity is inferred. Missing cells/columns report missing; absent units and unsupported notation report unresolved without partial numeric components.

Single dimensions, more than three components, fractions, mixed inline units, axis labels, comma notation, footnotes, ranges, zero/negative dimensions and unrecognized units remain unresolved. Input length is bounded to 256 characters. The original row's partial-recognition and mapping warnings still apply to these unreviewed interpretations.

## Verification

- 300 shared tests pass. Three new tests cover reference factors/order, invalid and ambiguous sequences, and real PDF extraction with interpreted/missing/unresolved rows plus JSON round trip and unchanged originals.
- Native iPad simulator acceptance passes in 16.730 seconds. It verifies the literal `24 x 36 x 48` and ordered `0.6096 × 0.9144 × 1.2192 m` display, then checks a missing dimension cell. This is a controlled host using production views, not physical-device or engineering acceptance.
- Repository and installed-plugin real-engine checks verify all three states, row-ID joins, exact original text and unchanged PDF/map bytes.
- Mac compilation passes; production package/source files match the isolated native copy. The screenshot was inspected, with converted text at the lower scroll edge; the native assertion verifies the full value.
- CI includes the dimension verifier; its 17 run steps pass local shell syntax checks. Hosted execution remains unverified.

The fixture SHA-256 is `c4a2b25f89d831f29a80857271e9721098bfe58b6c2366b5b1c4e07b22e1907c`. `Tools/create_dimension_schedule_fixture.py` regenerates the controlled PDF/map. `Tools/verify_schedule_dimensions.py` exercises the real plugin command; use a new output directory. Native harness test source is `Tools/fixtures/ScheduleDimensionUITests.swift` with the existing schedule host and dimension fixture injected in an isolated copy.

Installed plugin version: `0.1.0+codex.20260910195021`. The prior generated build cache was preserved before the extraction-result layout rebuild. Generated logs, source hashes, screenshot and plugin summaries remain excluded under `output/verification/schedule-dimensions/`.

A concurrent correction already present in the worktree prevents long fractional schedule quantities/phases from rounding into integers. It was preserved and all six numeric-interpretation tests were separately verified before dimension work; this turn did not duplicate that change.

Complete unit-convention handling, mixed dimensions and axis semantics, automatic detection, confirmed equipment associations, full engineering methods, REST/cloud, authenticated Ops publication and broader device/export acceptance remain unfinished. The full application objective remains active.
