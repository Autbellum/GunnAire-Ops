# Add LoadSight mechanical workspace and GunnAire Ops plugin

## Behavior

Add the shared Swift mechanical estimating engine, native Mac/iPad workspace, asynchronous SDK, CLI and portable Codex plugin. Ops Estimates opens the workspace with customer/job context and local draft recovery. Catalog mapping retains purchase units, conversion evidence and quote dates; changed evidence reopens review. Missing quantities and costs remain unknown.

Include native XLSX material-cost/history exports, PDF proposals and DOCX RFI/change-order drafts. Drawing-text extraction identifies source-anchored tag, airflow and thermal-rating occurrences for human review, with original-page preview and local RFI handoff. Occurrences do not become physical quantities or equipment associations automatically.

Add mapped equipment-schedule reading through the SDK, plugin and native source-review workspace. Explicit column maps preserve literal cells, unknown values and possible cross-view tag links. The 16.063-second synthetic iPad row/source/missing-MCA test passes.

Add native schedule map authoring with source/page selection, body and column bounds, literal headers/units and revision history. Package, portable JSON and recovery storage preserve maps and originals. Shared save/remove operations reject stale edits and reopen QA; plugin commands review and read saved maps.

Add separate numeric review for supported explicit scalar units, with native factor/offset disclosure and unchanged literal source rows. Missing and ambiguous units remain unresolved.

Add conditional schedule consistency findings with missing/unmapped distinctions, normalized-value comparisons and native basis disclosure. Unresolved units, partial rows and low-confidence evidence withhold comparisons; results do not approve equipment.

Add sourced schedule-finding RFI drafts with current-row validation, captured drawing-session protection, a readable source summary and a linked complete JSON evidence snapshot. Saving records an unanswered local question atomically; no external message is sent.

Add ordered dimension conversion to metres for explicit supported length units, with unknown/ambiguous sequences held unresolved. Original text and dimension order remain intact; no axes or physical quantities are inferred.

Add source-defined unit conventions for ambiguous thermal and flow units, with required legend/specification citations, compatible-field validation, retained map history and native disk-reopen acceptance. Literal units remain intact.

Add automatic supported-table discovery with source-bound header/tag evidence, literal units, unknown/duplicate header gaps and editable map drafts. Native source review and authored save are separate from discovery; no physical quantities or approvals are generated.

Include contributor instructions, regression CI, plugin boundary tests and repository handoff documentation.

## Verification

- Latest recorded source snapshot: 322 Swift tests passed; Mac and unsigned iPad builds passed.
- Twelve portable wrapper tests and plugin manifest validation passed at handoff.
- Repository and installed plugin extraction checks preserve original input and reject stale references and overwrite.
- Synthetic iPad source-preview/RFI test passed in 29.047 seconds. Earlier catalog, quote and native workbook acceptance is linked from `REPOSITORY_READY.md`.
- Native map entry, validation-error correction, disk save and reopen passed in 72.413 seconds; the plugin reads three rows from the actual native package. See `Reference/verification/Schedule-map-authoring.md`.
- Native numeric review passed in 12.123 seconds; repository/installed plugin checks verify converted airflow and preserved unknowns.
- Native consistency disclosure passed in 14.217 seconds; repository/installed plugin checks cover conflict, missing and no-conflict fixture rows.
- Schedule RFI package/JSON and repository/installed-plugin checks preserve exact source evidence and reject stale/invalid requests.
- Native schedule-finding RFI save/register acceptance passed in 27.427 seconds, including saved-field disabling.
- Native dimension/missing-cell review passed in 16.730 seconds; both plugin copies verify the three-state fixture.
- Native source-convention validation, save, disk reopen and value review passed in 92.835 seconds; repository/installed checks and the actual native-package plugin handoff passed.
- Native discovery, source inspection, authored map save and disk reopen passed in 25.155 seconds; both plugin copies and the actual native-package handoff pass.
- CI YAML and all 19 shell steps pass local syntax checks.

The latest schedule native source snapshot matches production at handoff. Run regression checks on the final reviewed commit. Hosted CI and physical-device acceptance remain unverified.

## Remaining scope and review boundaries

Full engineering methods, geometry and schedule association, REST/cloud services, authenticated Ops publication and broader device acceptance remain in `BUILD_STATUS.md`. This milestone does not complete the application.

The working tree also contains active Ops/backend development. Select reviewed changes and their integration dependencies explicitly; do not stage the entire workspace. Generated build evidence stays excluded. No new release license is assigned. See `REPOSITORY_READY.md` for the reviewed GitHub base and file inventory.
