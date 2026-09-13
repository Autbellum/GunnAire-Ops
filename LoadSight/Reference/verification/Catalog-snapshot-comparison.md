# Catalog snapshot comparison — 2026-09-10

The shared core compares a saved material snapshot with records supplied by the host when the editor opens. Results distinguish unchanged, changed, missing, ambiguous, different-source and older-source records. Unknown purchase costs remain distinct from zero; equivalent timestamp instants compare equal. Comparison alone does not mutate the project or invalidate QA.

Selecting another source clears the prior USD confirmation, purchase unit, conversion factor and compatibility basis. The estimator supplies that evidence again before applying the normal audited mapping edit. Missing records do not establish deletion, and supplied timestamps do not prove live supplier freshness.

## Recorded verification

- 201 shared Swift tests passed, including seven comparison/form tests.
- Native Mac and unsigned iPad compilation passed.
- `CatalogComparisonUITests.testReviewChangedSourceAndApplyExplicitConversion` passed: one test, zero failures, 32.608 seconds.
- The isolated harness uses the production shared editor with a synthetic in-memory project and supplied catalog. It reviews $50 to $75, confirms cleared conversion evidence, enters a 0.2 conversion, applies, and reopens at $15 per takeoff unit with a matching source status.

Harness sources are in `Tools/fixtures/CatalogComparisonApp.swift` and `Tools/fixtures/CatalogComparisonUITests.swift`. They replace the app entry point and UI-test source only in an isolated copy. They are not production entry points and are not automatically run by the hosted workflow. Logs and the production snapshot manifest are retained locally under `output/verification/catalog-comparison/`.

This verifies the shared editor with synthetic supplied records. Live Ops refresh, supplier quote validity and physical-device behavior remain unverified or unimplemented.

## Plugin contract verification

The repository and installed plugin now expose `catalog-compare project.json --catalog supplied-catalog.json`. The version-1 report preserves item edit fingerprints and mapping currentness; unmapped items have no comparison. Inputs require all eight snapshot fields, including explicit purchaseCost null when unknown. No output or edit flags are allowed.

The combined source suite passed 209 tests after integration, including three new contract tests; eight wrapper tests passed. `Tools/verify_catalog_comparison.py` ran against both repository source and installed version `0.1.0+codex.20260910181238`, covering unchanged, changed, unknown cost, missing and ambiguous records. Both runs rejected unknown fields, preserved project/catalog input bytes and emitted five valid reports. The existing core tests additionally cover different-source and older-source records. Installed wrapper, manifest and reference hashes match personal source. Evidence is retained locally in `output/verification/catalog-comparison-plugin/`.

The GitHub workflow runs the same verifier using its generated synthetic mapping fixture. Hosted execution has not been observed. This command does not produce an automatically applicable mapping or establish supplier quote validity.
