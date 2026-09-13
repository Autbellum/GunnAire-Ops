# Asynchronous native workbook export — 2026-09-10

Native Takeoff now uses the local SDK actor to prepare XLSX bytes from a captured project and drawing archive, instead of generating the workbook on MainActor. The existing native archive validation and workbook content are preserved. Takeoff displays progress and a Cancel export control while preparing. Cancellation is cooperative at the engine call boundary; late results/errors cannot reopen a cancelled preparation.

A document-session change or workspace disappearance cancels preparation. Generation IDs reject obsolete results. Save-panel completion/cancellation clears only its matching receipt, so a late receipt cannot clear a newer document's export. A workbook is an output snapshot and never marks the project saved, clears recovery, changes costs or completes QA. Edits made after preparation starts are not silently inserted into that workbook.

## Verification

- **236 shared tests pass** in the combined tree. Four preparation tests cover engine-output equivalence/source preservation, cancellation of running work with a late return, visible failure without an export, and stale receipts against a new document session.
- Native Mac build passes. The arm64 iPad simulator build passes in an isolated copy with matching production source hashes.
- `WorkbookExportUITests.testPrepareWorkbookAndCancelSavePanel` passes in **17.154 seconds**, opening/cancelling the native panel twice and confirming export becomes available again.
- `WorkbookExportUITests.testSaveWorkbookToLocalFiles` passes in **15.632 seconds**, saving a uniquely named workbook through Files into the simulator's LoadSight Documents folder. The app returns to Takeoff with export enabled and no error alert; the final screenshot was inspected.
- The actual saved XLSX was copied and checked with `Tools/verify_native_workbook_export.py`: five expected tabs, source row CMP-1, quantity 10 LF, saved material cost $10 per LF, and preserved catalog source/history. The workbook uses the saved $50 × 0.2 mapping, not the supplied but unapplied $75 catalog record.

Local evidence is under `output/verification/workbook-preparation/`, including the saved workbook, hashes, exact executed-test results, logs and screenshot. The test app is the synthetic `Tools/fixtures/CatalogComparisonApp.swift`; tests are in `Tools/fixtures/WorkbookExportUITests.swift`. Only the app entry point and test source are replaced in the isolated harness. Original simulator documents were retained; the saved filename uses a new UUID.

## Scope limits

The native runtime tests verify local Files saving and save-panel cancellation with synthetic data. Preparation cancellation and stale receipts are verified at controller level; large-project cancellation latency, mid-export device loss, third-party Files providers, native Mac save-dialog interaction, and physical-device acceptance remain open. The shared engine call cannot be forcibly interrupted mid-calculation. Other document exporters still need migration to the async service. Full engineering/extraction and authenticated Ops publication remain part of the active objective.
