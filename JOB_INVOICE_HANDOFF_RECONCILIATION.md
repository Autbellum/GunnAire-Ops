# Original-invoice job handoffs

This follow-up builds on the reviewed-draft receipt in
`MILESTONE_DRAFT_RECONCILIATION.md`. It is not proof of full-suite, production
provider, or signed multi-device readiness.

## Workflow changes

- Schedule resolves a job's historical draft link to its exact reviewed original
  before showing the balance, collecting, or finding payments needing QuickBooks
  attention. A retained draft's zero reporting contribution is not payment.
- Missing invoice/customer relationships display a pending/review state rather
  than Paid. A blocked invoice does not offer a collection action.
- Documentation Queue opens collection for the reviewed original invoice. An
  unavailable, blocked or settled link offers Review Invoice instead of a
  payment action. Valid retained drafts are excluded from active closeout rows.
- Documentation without a stored invoice link may use only one exact invoice
  for the same customer object and job. Ambiguity, foreign customers/jobs and
  temporarily missing CloudKit customer relationships never authorize a guess.
  A present but unavailable historical link cannot fall through to another bill.

The original stored job link, both invoice UUIDs, saved amounts, attachment
ownership and accounting records remain unchanged. Opening the collection form
does not record or send a payment. Tests cancel the Record Payment sheet.
This follow-up adds no persistence field, entitlement or provider request.

## Evidence

Retained evidence root:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Job Invoice Handoffs.dOJMug`

- `BeforeFix.xcresult`: both initial tests failed. The Schedule failure directly
  reproduced the missing $189 balance after retaining the duplicate. The first
  Documentation test expected the wrong destination title; it is not on its own
  proof of the routing defect.
- `AfterFixIPad.xcresult` and `CorrectedIPad.xcresult`: each passes 1,413 logic
  tests and five of six UI journeys. The remaining Documentation assertion
  exposed test setup issues: its intended destination is Record Payment, and
  a launch-domain Invoices route kept overriding runtime navigation. The retained
  `BeforeDocumentation.png` video frame shows the unintended Invoices return.
  Neither result is reported as a passing full run.
- Cross-workspace tests now enter Invoices via the ordinary sidebar without a
  pinned launch route, verify the original $189 amount on the appropriate
  collection screen and cancel without recording a transaction. Existing
  single-workspace review tests retain their prior launch configuration.
- `AfterFixMac.xcresult` passes 1,413 logic tests across 42 suites in 10.719
  seconds. Sequential `MacSummary.json` and `MacTests.json` exports verify the
  complete target and reconciliation suite. Concurrent initial exports hit an
  xcresulttool database-extraction collision; sequential inspection of the same
  terminal bundle succeeded without rebuilding or deleting evidence.
- `UniversalMac.log` records a successful unsigned Release build. Both arm64
  and x86_64 executable architectures were verified.
- `FinalIPad.xcresult` passes 1,413 logic tests across 42 suites (10.888 seconds)
  and all seven selected UI journeys (231.060 seconds), 1,420 total executions.
  `IPadSummary.json` and `IPadTests.json` verify all eight selectors: the logic
  target, Invoice, Mail, retained-draft reopening, both new handoffs and the two
  existing Schedule collection/closeout journeys. Nothing was skipped.
- Both final collection screenshots were visually inspected in
  `FinalScheduleScreens` and `FinalDocumentationScreens`. Each shows the correct
  customer and $189 amount with no account-email footer. The existing closeout
  screen still shows a QuickBooks reference; broader UI simplification remains
  separate from this identity/routing correction.
- `FinalSource.sha256` binds the five changed source/test files. Production
  sources and logic tests did not change after the passing Mac/Release builds;
  subsequent changes correct only the cross-workspace UI-test setup/assertions.

## Publication and remaining work

The preceding qualified reconciliation is applied to the original iCloud project
and published as source `8265b13`, with workflow `0fa15fe` in PR #18. That workflow
retains all 41 earlier journeys and adds retained-draft review (42 total). Backend
checks pass; exact-head native checks remain separate. PR evidence:
<https://github.com/Autbellum/GunnAire-Ops/pull/18#issuecomment-5586360767>.

The locally qualified handoff follow-up is copied exactly to the original
iCloud project. All seven source/test/document paths match; 215 unrelated changed
files and the original project's empty index were preserved. It is retained as
a separate local review commit, not included in published head `0fa15fe`.
Hosted scheduling and exact-new-head verification remain required.

The prepared 44-selector workflow adds both handoff journeys, preserves all 42
published selectors and passes actionlint; it is not yet published. The preceding
native CI run is allowed to finish rather than being cancelled for this follow-up.

Legacy estimate/receipt attachment defaults still have raw historical-link
consumers requiring a separate evidence-backed audit. The Documentation Queue's
empty-state wording also needs a dedicated pending-CloudKit acceptance pass:
unresolved customer rows are excluded safely, but must not imply every invoice
is finalized and paid. Signed physical CloudKit
arrival/convergence, mixed-version clients, physical collection/Handoff/Tap to
Pay, approved provider acceptance and all remaining ten-suite/Google/vendor
requirements remain open. No merge, deployment, schema promotion, signing
change, physical installation or live accounting/payment action occurred.
