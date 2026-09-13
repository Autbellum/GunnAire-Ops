# RFI routing and response planning

The native RFI editor and shared rfi.create/rfi.edit operations now support To, From, Request date, Required response date and Suggested resolution. Fields remain optional. Names are recorded text, not authenticated identities or contact lookups. Dates are blank or actual Gregorian dates in YYYY-MM-DD format. No current date, sender or deadline is inferred. Past deadlines remain as recorded; neither saving nor exporting sends an RFI or creates a reminder.

The structured optional communication object replaces all five text values. Omission preserves an existing record, including edits from older clients. Supplying all five empty strings explicitly clears them. Partial objects, null, unknown nested keys and nontext values are rejected. New records use communicationVersion1 alongside the existing RFI workflow version. Legacy unversioned imported values remain readable; saving them through the new form applies current date validation rather than silently reformatting them.

Changes use the existing RFI lifecycle: only open questions are edited; saving reopens QA and records complete before/after snapshots. Resolve/reopen preserves routing facts and planning dates. Unsaved communication edits are included in the native resolution guard. The Word exporter includes supplied current and historical routing/planning values. Native history exposes previous and saved routing and plan sections.

## Verification

123 XCTest tests passed in output/verification/rfi-communication-tests.log. Five new tests cover leap years/impossible dates, blank and historical deadlines, omitted-field preservation, explicit clearing with history and fingerprint/QA changes, failed-edit atomicity, strict nested schema, unsupported versions and native package/JSON round trips through resolution/reopening.

Mac and generic iOS Simulator builds passed: rfi-communication-mac-build.log and rfi-communication-ios-build.log. Native field interaction and export-dialog acceptance remain unverified in this pass; model package round trips do not substitute for those interactions.

Installed plugin 0.1.0+codex.20260910161200 passed manifest validation, the existing 20-operation workflow in output/verification/rfi-communication-installed-plugin.json, and the dedicated Tools/verify_rfi_communication.py workflow. Its output/verification/rfi-communication/summary.json proves create/edit, omission preservation, explicit-clear history, invalid/null/partial rejection, Word current/history text, overwrite rejection and unchanged source.

The populated Routing-review.docx was rendered using the bundled documents renderer and bundled LibreOffice. All three pages in output/verification/rfi-communication/render were visually inspected for current values, before/after history, wrapping and legibility. No recipient or deadline was substituted from the fictional verification fixture into a user project.

Remaining overall work includes change orders and DOCX, complete room/building/distribution methods, extraction, authenticated release, direct Ops integration and broader native acceptance. The original goal remains active.
