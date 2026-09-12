# Retaining an unused milestone draft

This is a local candidate, not a production release or proof that the full
business-suite objective is complete. It builds on the shared milestone identity
contract in `SHARED_MILESTONE_BILLING.md` and preserves both original documents.

## User workflow

An administrator or accounting user opens Billing Review for a duplicate
milestone draft. The shared publisher must identify a confirmed original, and
that exact invoice must have arrived in the current local business store.
The user can open the original, review its saved allocation, then explicitly
retain the unused draft. The action does not send, publish, cancel, void, pay,
delete or merge either invoice.

Retained drafts appear in a collapsed office-only section rather than the active
invoice queue. Their saved details and attachment names remain available in
Billing Review; the original files remain linked in the existing Files workspace.
The original invoice keeps its own date, prices, tax, payment history and IDs.

Jobs that historically linked to a retained draft follow the reviewed original
in their billing and collection views. The stored job link is not rewritten.
An absent or changed original leaves a blocked draft visible; it must not look
like an empty job needing another invoice.

## Authority and evidence

The native workflow performs only scoped shared-service GETs:

1. Confirm current company/realm/environment, customer/job/stage and office role.
2. Fetch the exact confirmed original publication and saved proposal.
3. Check that the duplicate draft has no non-cancelled publication history and
   no local pending publication journal.
4. Re-read current office authority and durable milestone ownership.
5. Recheck both local documents, captured workspace/access and one active local
   reviewer before saving the review receipt.

The draft must be unissued, unsigned, unfinalized, unpaid and without any local
or provider payment/balance/sync evidence. Ambiguous local identities, a wrong
customer/job/stage/provider, changed documents or lost authority require review.
Save failure restores only the new receipt field, not unrelated context edits.

The optional receipt records the scoped original invoice/publication/provider,
local reviewer UUID, review time and a digest of the retained draft. It is a
local office-review record, not a payment, new accounting entry or server-signed
certificate. It does not grant permission to publish or collect.

## Financial projections and storage

Only a valid receipt with the exact available original excludes a retained draft
from active invoice totals. Reports, customer statements, account intelligence,
dashboard balances and project milestones follow that projection. An unresolved
duplicate or invalid receipt surfaces review rather than verified totals.
The original's date controls period reporting; retaining a newer duplicate does
not move old revenue into the current period. A retained draft is not labelled
paid and cannot be collected, edited or republished.

Native CloudKit bootstrap candidate 26 adds only the optional string
`CD_Invoice.CD_milestoneDraftReceiptJSON`. Preflight and promotion-manifest tooling
retain prior schema gates and identify this exact additive delta. A v25 export
still requires staging the new field; no production schema promotion has occurred.
A real legacy SQLite migration test removes the field from a copy of the actual
generated model, creates the old store, and opens it with the current schema.

Apple documents asynchronous relationship arrival and additive CloudKit schema
requirements: [Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices).
An additive field does not prove safe mixed-version business behavior: older
clients do not know to exclude retained drafts. Signed multi-device and
mixed-version acceptance remains required before release.

## Evidence and unresolved work

Evidence is retained under:

- `2026-09-08/Milestone Reconciliation.ltUxOa`: 1,402 Mac logic tests, including
  the actual SQLite migration, pass in `FullMac.xcresult`; 52 tooling tests pass.
  The retain/reopen UI journey passed all three repetitions in
  `RepeatedIPad.xcresult`, while the pre-existing hardware-keyboard replacement
  journey failed two of its three repetitions. That bundle is not a passing run.
- `2026-09-08/Keyboard Editing.z1bmue`: completed local diagnostics and job
  handoff qualification. `JobHandoffMac.xcresult` passes 15 reconciliation tests;
  `CorrectedBoundaryMac.xcresult` passes 20 tests across the model and shared-read
  workflow suites, including revocation at every awaited read, changed originals,
  late payments, role loss, foreign scope, existing alias history and save failure.
  `FinalMac.xcresult` passes 1,410 logic tests across 42 suites;
  `FinalIPad.xcresult` passes the same 1,410 logic tests and all ten selected UI
  journeys, including Invoice opening, the simple Mail inbox, touch/keyboard
  bundle editing, retained-draft review and original-invoice return navigation.
  Authoritative execution trees verify all requested selectors. `FinalBackend.log`
  records 564 passing tests and `FinalTools.log` records 52. `UniversalMac.log`
  records a successful unsigned Release build; both arm64 and x86_64 executable
  architectures were verified. All 22 source/test/tool hashes in
  `FinalSource.sha256` still match the qualified files.

Keyboard diagnostics rejected two proposed explanations: retaining a SwiftUI
TextSelection binding and targeting XCUIApplication instead of the field both
reproduced the expected `2` versus actual `1.02` failure (one pass, two failures).
Those changes were removed. Fixture-only tracing then confirmed that the field
kept focus, but failed runs never entered a selected range after Command-A.
Initializing physical-keyboard input with a modifier event before field focus
passed all three repetitions in `InitializedHardwareIPad.xcresult` (82.168,
80.701 and 81.971 seconds). The test still sends exactly one Command-A and one
replacement key per field, with no deletion or retry fallback. This supports
a synthesized-input initialization problem; it is not a physical-device finding.
The temporary probe and selection-binding experiment have been removed; the
production bundle text-field implementation is unchanged. The probe-free
`FinalRepeatedHardware.xcresult` passes all three repetitions (76.789, 74.400 and
74.923 seconds), in addition to the keyboard journey in `FinalIPad.xcresult`.
The repeated result's test tree verifies the exact selector and its device
summary and log verify all three executions, not three different test cases.

All three retained-draft/original-invoice screenshots in `FinalRetainScreens`
and both edited/saved bundle screenshots in `FinalKeyboardScreens` were visually
inspected. The original invoice remains $189.00; the edited bundle saves $283.50
with its original customer and system. No account-email footer or raw receipt
metadata appears in those captures.

Publication remains separate: preceding PR #18 head `aaaaf68` added the two
prior shared-milestone journeys (41 selected UI tests). Its Backend and Mac jobs
passed; its iPad job finished at 2026-09-08 13:50 UTC with exactly one failure in
41 UI tests: the hardware-keyboard replacement journey. Safari inspection of
job 102070656286 confirmed that failure, not a timeout; the evidence was retained.
This reconciliation candidate includes the locally qualified keyboard-test
initialization, and a prepared workflow adds the retained-draft journey without
removing any previous selector (42 total). New-head hosted results remain a
separate gate. All 24 candidate files were copied exactly to the original iCloud
project; hashes verify 197 unrelated changed files were preserved and the
original project's index remains empty. No active hosted run was restarted.

The continuation audit also found Schedule, Documentation Queue and selected
legacy receipt/estimate paths still resolving a raw historical invoice link.
Those consumers require focused follow-up and UI acceptance; the qualified
job-detail and dashboard helpers do not prove every app handoff complete.

Remaining scope includes signed physical CloudKit convergence, mixed-client
rollout, conflicting replicas with the same model UUID, legacy invoices lacking
provider milestone references, broader physical/multi-device reconnection
acceptance, general staged cent allocation, live approved provider acceptance,
and the full ten-competitor, Google/vendor/access and iPad-to-iPhone Handoff /
Tap to Pay objective. No production accounting action, deployment, signing
change or schema promotion is authorized by these local tests.
