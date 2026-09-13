# Supplier quote evidence and validity — 2026-09-10

## Implemented behavior

A catalog cost mapping can record a supplier, quote reference, source document/correspondence, issue instant, optional expiry instant and commercial conditions. This evidence belongs to the exact saved cost/unit mapping. Full before/after mapping history, portable JSON and workbook history retain it. Unknown expiry is explicit null; no date is inferred from a catalog update timestamp.

Expiry is exclusive and must follow issue. Dates include a timezone; interpretation of date-only supplier terms belongs in the recorded conditions. Review distinguishes within-recorded-period, expired, expiry-unknown and not-yet-issued. Normal pricing review evaluates the current time, and holds release for the latter three states on included rows. Draft cost amounts remain available. The core also accepts an explicit `asOf` for deterministic reviews. Time passing changes review eligibility without rewriting saved QA/history or costs.

The native editor can enter, revise and remove quote assertions through the existing audited mapping save. Selecting a different catalog source clears quote evidence together with purchasing-unit/currency assertions. Legacy mappings have no quote assertion and retain their existing price-source review requirements. A recorded period does not prove supplier availability, authenticity, freight/tax completeness, or approval.

The plugin accepts optional `mapping.quote` through `catalog.material.update`, with strict nested fields and explicit null expiry. `catalog-review` adds `reviewedAt` and nullable per-item `quoteReview`. Installed source is `0.1.0+codex.20260910181642`; wrapper, manifest and reference hashes match personal source.

## Verification

- 213 shared tests passed in the combined source tree. Four quote tests exercise issue/expiry boundaries, timezone equivalence, unknown/invalid dates, read-only expiry effects on pricing, persistent history, strict plugin edits and form reset/legacy behavior.
- Eight wrapper tests passed; Mac native bundle build passed.
- `Tools/verify_supplier_quote.py` passed through both repository and installed plugin: four states, preserved costs/source bytes and malformed nested input rejected. The CI workflow runs this verifier on its generated synthetic material fixture.
- Native XLSX structural/source verification passed for an expired-quote project: five sheets, thirteen mapping revisions and 246 history rows. Every quote field was reconciled to its original before/after history value. This check does not establish new visual or native Excel acceptance.
- Native iPad entry/save/reopen acceptance passed: one test, zero failures, 83.070 seconds on the iOS 26.2 iPad simulator. It enters all quote fields, saves/reopens, checks the period message and exact reference/expiry, and retains a screenshot that was visually inspected. The harness uses synthetic in-memory data and the production editor; it does not use a live supplier or customer project. Production source hashes still match the captured build snapshot. Three earlier harness attempts exposed switch targeting and off-screen field queries; the final test targets the nested switch and uses actual sheet navigation bounds.

Local evidence is in `output/verification/supplier-quote/`. Harness sources are `Tools/fixtures/CatalogComparisonApp.swift` and `Tools/fixtures/SupplierQuoteUITests.swift`; the app entry point and UI test are replaced only in an isolated build copy. Production source hashes were captured before the build.

## Remaining scope

Supplier API retrieval and quote authenticity/availability checks, quote-document extraction, standalone non-catalog supplier pricing, authenticated Ops publication, physical-device acceptance and the remaining engineering/extraction requirements remain open. No supplier order, accounting mutation, or external message is performed by this workflow.
