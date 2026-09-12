# Bundle-aware staged project billing

September 8, 2026. This is an implementation/qualification checkpoint for the
full business-suite objective, not a production release or complete-app claim.

## Corrected workflow

The original milestone code computed `unitPrice * quantity` on each top-level
line. A QBO bundle header has no charge: its ordered sold components carry the
price. A bundle-only approved estimate therefore could not create a progress
invoice; a mixed estimate could allocate against the wrong scope. Independent
calls also divided arbitrary cents by price into repeating quantities that the
existing strict provider boundary could not publish.

`ProjectProgressAllocation.documents` now plans the entire contract together.
Its output is ordinary invoices through the existing QBO publication workflow;
it does not invent a provider progress-invoicing endpoint or mark payments paid.

- Every milestone receives its planned net cents. The approved document discount
  is apportioned once, becomes a fixed amount per stage, and retains the original
  reason, actor and date. Zero-cent portions do not create a discount line.
- A Decimal largest-remainder matrix conserves each sold occurrence's gross
  cents as well as each stage's gross subtotal. Later stages draw only from the
  remaining approved balances, not a new copy of the original full charge.
- Integer quantity bounds use the existing native five-decimal sales contract.
  The selected quantities must produce the exact line cents at the original
  price and sum to the exact original quantity across every stage.
- Bundle headers remain zero-charge Group lines; ordered member UUIDs, repeated
  products, type, scope, tax, cost, serviced-equipment evidence, price-override
  audit and customer display preference remain intact. No catalog is repriced.
- Quantities that are zero for a stage are omitted from that invoice, not sent
  as invalid zero-quantity lines. The original approved snapshot remains whole.
- Actual issuance calculates all stages in stable sequence and reconciles
  already-issued original invoices before allowing another. Missing relationship
  records, missing invoices, duplicated links, foreign customers, orphan stages,
  changed sold snapshots or changed saved allocations require sync/review.
  Issuing completed stages out of sequence does not change their allocations.
- Plan creation checks the whole allocation before any plan record is inserted.
  The setup sheet explains before-tax scope, uses the iPad-compatible numeric
  keyboard and stays open when its parent cannot save. No new navigation tab.
- The staged contract is the approved **subtotal**, not subtotal plus estimated
  sales tax. Each invoice obtains its own tax result through the existing tax
  workflow. Project invoiced/backlog figures use subtotal; the project payment
  progress figure attributes partial collections proportionally before tax.
- Reviewed tax addresses travel with each invoice; the actual issuance checks
  them against the original customer/property and the target job. Original
  invoice reconciliation subtracts integer total/tax cents, not a binary Double
  difference that can turn $0.10 minus $0.01 into 0.09000000000000001.
- Job material closeout continues to use the full approved project estimate.
  A deposit's fractional invoicing is not another stock consumption, nor does
  it reduce the physical installation requirement to the deposit's fraction.
- Failed local invoice saving also restores the original job status.

No new SwiftData field, schema version, entitlement, signing identity or provider
credential is introduced. Optional existing JSON carries the bundle evidence;
that does not prove older clients can safely edit these documents.

## Evidence and retained failures

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Milestone Bundles.tJ7MkG/`

Xcode 26.6 (17F113), deployment iOS 26.0, Mac Catalyst and 13-inch M5 iPad
Simulator (iOS 26.2). Tests use isolated data and no live accounting transport.

The first focused run, `FocusedMac.xcresult`, is retained as a **failure**:
three of nine new tests failed. Repeating fractional Decimal values converted
through `NSDecimalNumber.int64Value` returned zero on this Foundation build.
An independent `swift -e` reproduction produced `0` for
`14285.714285714285714285714285714285714`; Decimal rounding to an integer first
produced `14285`. The allocator now removes the fractional part in Decimal
before converting. No conservation assertion was relaxed.

`CorrectedMac.xcresult` passes all **1,376 logic tests in 39 suites**; the actual
xcresult tree is checked with `Tools/verify_native_test_execution.py`, not only
xcodebuild's exit message. Eleven focused allocation tests cover real QBO Group
line construction, repeated members, edited equipment/price/tax evidence,
seven-stage discounts, fractional/free rows, unrepresentable price splits,
malformed plans, prior-invoice recovery, before-tax scope, full-job stock,
temporarily missing CloudKit relationships and out-of-order stage issuance.

`CorrectedIPad.xcresult` passes those logic tests and four UI methods, but visual
inspection of its retained screenshot found a real remaining review defect:
the persisted $5,550 invoice appeared below an empty editable builder with a
$0 total. Passing creation/locked-button assertions did not prove a useful
review interface. That screenshot remains under `Screens/`; it is not a visual
acceptance result.

`ProjectProgressInvoiceReview` now reads the saved invoice directly. It shows
the original group, expandable members, exact subtotal/total and due date, with
no Add/Create/Update controls for the locked allocation. Billing Review remains
the publication/recovery handoff in the same job. The strengthened UI assertions
require the actual saved $5,550 subtotal, both $2,775 member rows at quantity
0.3, the lock, and absence of editing controls. `ReadOnlyIPad.xcresult` passes
the four journeys; the expanded allocation screenshot in `ReadOnlyScreens/`
was inspected and contains neither the empty builder nor an account-email
footer. These results precede the final address/currency-reconciliation changes.

Final-source logic now passes **1,378 tests in 39 suites on each platform**,
including thirteen dedicated allocation tests. `FinalMac.xcresult` and
`FinalIPad.xcresult` retain those executions. The final iPad run additionally
passes **five UI journeys** (1,383 total tests, no failures or skips): ordinary
milestone creation/review, bundle milestone creation/read-only component review,
category/bundle invoice composition, Invoice opening, and the simple Mail inbox.
The execution verifier confirms all six selectors against actual test nodes.
`FinalUniversalMac.log` passes the unsigned Release build; `lipo -verify_arch`
confirms arm64 and x86_64. Existing optional Metal-toolchain search-path warnings
remain; no new source warning is reported in the final native runs.

`FinalScreens/5EF9838E-799B-432D-9343-F1843297DA35.png` is the inspected final
bundle allocation: saved group and two separate $2,775 components, quantity
0.3, $5,550 subtotal/total, lock, and Billing Review handoff. It has no editable
zero-dollar builder or account-email footer. `FinalSource.sha256` records all ten
tested Swift source/test files; final byte verification passes.
Unchanged Backend passes **546 tests** (`Backend.log`, 61.123 seconds), and Tools
passes **51 tests** (`Tools.log`). No provider, production or signed-device result
is inferred from these local runs.

This checkpoint is retained locally on the existing review branch and copied
to the original iCloud Xcode project after a base-match check. The preceding
published head remains `e612485` on open, unmerged PR #18. Its Backend and Mac
jobs pass; the exact iPad run `34214902054` is still live at this checkpoint.
No push is used to cancel that in-flight acceptance run. Publishing this source
and adding the two milestone UI selectors to GitHub CI are still required.

## Required continuation and acceptance

- Exact-price allocation has genuine representability limits. For example,
  $3,333.33 cannot be expressed as a five-decimal quantity at $10,000 per unit.
  The current bounded allocator also does not search every alternative
  cross-component cent redistribution when its proportional matrix is
  unrepresentable. These cases retain the original contract and need allocation
  review; they are not silently repriced, flattened, rounded or overbilled.
  Broader feasible-plan allocation and its administrator review UX remain work.
- Existing invoices made by an older independent-allocation algorithm must be
  reconciled to the original issued documents. They are never rewritten to fit
  the new plan. Automated remaining-balance planning for such histories still
  needs implementation and acceptance.
- Ordinary QBO invoice/group/tax/inventory acceptance needs concrete authorized
  sandbox targets. These local tests do not prove provider tax or stock results.
- Signed physical iPad/Mac CloudKit sync, mixed-version bundle compatibility,
  service-location isolation and full plan-edit/recovery UI qualification remain
  required. SQLite/in-memory tests are not physical CloudKit acceptance.
- Concurrent offline issuance on different devices is not solved by the local
  plan reconciliation alone. The current server billing identity is the local
  invoice ID, and native creation still generates a new invoice UUID; the server
  has no explicit milestone key in the inspected billing source. Shared
  business/estimate/milestone issuance uniqueness, including older-client
  histories and lost replies, must be implemented and tested before claiming
  multi-device duplicate prevention or promoting live project billing.
- Imported editable provider bundles, all remaining Google/vendor/access-level
  workflows, top-ten competitor coverage, physical iPad-to-iPhone Handoff and
  Tap to Pay, production deployment and distribution gates remain in scope.

## Primary references

Read in Safari on September 8, 2026:

- [Intuit Invoice API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/invoice):
  supported sales/group/discount lines, GroupItemRef/Quantity, tax line limit,
  provider-calculated totals, and automatic-email conditions. No live invoice
  was posted while reviewing this documentation.
- [Intuit Item API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/item):
  Group component identities and inventory/service classification.

The selected Swift, QBO, accounting, field-service, offline, access and reliability
skills guided exact source preservation, stock/accounting separation, recovery
checks, role boundaries, actual test execution and separate production gates.
Their resolved guidance and lifecycle are recorded in the skill-usage audit.
