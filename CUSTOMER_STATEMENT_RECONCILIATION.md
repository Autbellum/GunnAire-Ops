# Customer statement reconciliation and historical evidence

Review-only checkpoint, 2026-09-07. The full GunnAire Ops goal is still active
and incomplete. No live accounting, payment, message, deployment, signing,
CloudKit schema, or physical-device changes were made.

## Reproduced defects

Two simulator regressions failed against the prior implementation:

- A historical statement reused today's QBO zero balance / paid status, lost
  the previously open invoice, and included invoices/payments after the cutoff.
- Display-list heuristics grouped genuine local invoices by customer name,
  date, amount, or job. One customer's paid record could hide another customer's
  same-name invoice before the customer filter ran.

Reproduction: `/tmp/gunnaire-statement-reproduction-20260907.log`, result
`/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.07_00-14-30--0400.xcresult`.
The two failing test functions were observed, not merely inferred from code.

## Implemented boundary

Statements now use a dedicated financial projection. Customer identity and
invoice issue timestamps are filtered before grouping. Only durable local or
exact, case-sensitive QBO invoice identities may group records; distinct jobs,
equal amounts, and same-name customers do not determine identity.

Payment/refund activity includes timestamps through the exact inclusive cutoff,
including the boundary instant but excluding later activity on that same day.
Stable payment, attempt, accounting, and charge identities prevent duplicate
collections from reducing the statement twice. Different partial refunds
against one original charge remain separate. Conflicting identities/amounts
require reconciliation instead of an apparently valid customer total.

Calculations use integer cents. Invalid/nonfinite amounts, unexplained local
paid flags, missing/invalid/future-dated accounting balances, tax-pending
invoices, and unresolved cancellation states prevent export/email. The Files
section shows one review explanation and a direct **Review Invoices** handoff.
It does not display an incomplete total as zero or offer a send workaround.

Current statements retain saved QBO-linked balances without subtracting local
payments again. The PDF labels its exact activity cutoff, calendar time zone,
saved balance source, last accounting refresh where known, pending bank status,
and open-invoice scope. It does not claim a live refresh or a complete QBO
customer-account balance including unapplied credits. Generation and the email
draft use the same immutable projection, not a second recalculation.

The statement section was extracted from the large customer form to keep SwiftUI
type checking tractable; no new navigation workspace was added. Model/schema,
entitlements, deployment targets, and project manifest are unchanged.

## Historical statements are NOT complete

An explicit `asOf` requests a dated diagnostic projection. It never treats
today's paid flag, QBO balance, or last-sync timestamp as historical truth.
Customer PDF export/email of this projection is blocked because the existing
mutable Invoice/Payment models do not retain a complete versioned accounting
history. This includes a zero-entry projection: missing records are not proof
of a zero historical balance.

Previously saved statement files are untouched and remain available in customer
Files. The normal current-statement UI still works. A dated QBO report and
versioned local invoice/credit/reversal evidence must be integrated before a
date picker or verified historical customer statement is released. This guard
prevents a false statement; it is not a substitute for the requested completed
historical feature. Do not resolve the PR's historical-balance review as fully
implemented on the strength of this guard.

Intuit's primary SDK exposes report date, end date, customer, and aging options:
[ReportService](https://github.com/intuit/QuickBooks-V3-PHP-SDK/blob/master/src/ReportService/ReportService.php).
The public SDK [report names](https://github.com/intuit/QuickBooks-V3-PHP-SDK/blob/master/src/ReportService/ReportName.php)
include AgedReceivables and CustomerBalance. These references establish a
research direction, not acceptance of an unimplemented report parser, tenant
filter, credit allocation, historical mutation semantics, or provider result.

## Verification

- The 16 focused statement regression tests passed with zero failures/skips.
- Final M5 13-inch iPad / iOS 26.2: **811/811 logic and 4/4 UI tests passed**
  (815 total), zero failures/skips. UI covers current statement generation and
  saved-file preview, unreconciled statement-to-Invoices recovery, direct
  Invoice launch, and the simple Mail read/write/reply/delete journey.
- Final Mac Catalyst Debug: **811/811 logic tests passed**, zero failures/skips.
- Nineteen new logic tests cover the two reproduced bugs, exact timestamp
  boundaries, paid flags, historical export rejection, current accounting
  balances, duplicates/conflicts, distinct partial refunds, invalid amounts,
  calendar/DST aging, customer isolation, commercial invoice amounts, aggregate
  overflow without a trap, and generated PDF evidence. Reporting amounts are
  not limited by the separate financial-dispatch cap.
- Both pages of the final native PDF fixture were rendered with Poppler and
  visually inspected. Invoice rows stay together on a page when they fit;
  longer invoice sections receive a continued reference. The PDF has US Letter
  pages, readable cutoff/source/scope and pending-bank details, and no account
  email in the footer.
- The first complete runs had one PDF text-extraction assertion failure:
  PDFKit inserted a newline within the rendered-intact time-zone identifier.
  The final test separately verifies the stored calendar, whitespace-normalized
  extracted text, and invoice-section page cohesion. All final tests pass.
- The initial SwiftUI type-check timeout was corrected by extracting the
  statement section; no compiler setting or signing relaxation was introduced.
- Universal optimized Mac Catalyst Release built successfully; the produced
  binary contains both arm64 and x86_64. The pre-existing external missing
  Metal-toolchain search-path warning remains. Unsigned test hosts still emit
  AppShortcut/LinkDaemon/ScreenTime diagnostics; this is not signed acceptance.
- All nine changed files are byte-identical between the original iCloud
  workspace and review clone. The project manifest SHA-256 is unchanged:
  `52ecaabdb59c9d554d286f448a121eecd5a319afd6961bd9de62c3c075b315f7`.
- No provider or production writes are part of these checks.

Exact final results:

- `/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.07_00-39-26--0400.xcresult`
- `/tmp/GunnAireQBORefreshMac/Logs/Test/Test-GunnAire Ops-2026.09.07_00-39-25--0400.xcresult`

Retained evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07`.
Includes Statement iPad Acceptance.xcresult, Statement Mac Acceptance.xcresult,
Statement Accepted QA Fixture.pdf, accepted-page PNGs, and accepted build/test
logs. Earlier 809-test intermediate results are retained separately.

## Required next work

1. Implement/accept original-company-scoped dated accounting reports and
   versioned local invoice history, including edited totals, voids, credits,
   refunds/reversals, missing records and historical customer identity.
2. Audit remaining uses of `Invoice.displayDeduplicated` in Billing and other
   lists. This checkpoint stops statement-specific misuse; it does not remove
   the same legacy heuristic from every other workflow. Current call sites are
   BillingDocumentsView.swift (displayed invoices and unresolved relationships)
   and BusinessReporting.swift (period reporting and field-cash reconciliation).
   Two legacy tests currently encode same-job/amount collapsing and preferring
   a local paid flag over a QBO unpaid copy; those expectations require a
   durable-identity/accounting-evidence review, not blind preservation.
3. Continue the payment journal's server-owned financial/accounting dispatch,
   ACH returns/settlement, cross-channel coordination, and recovery gates.
4. Re-run signed CloudKit migration/convergence and production provider/device
   acceptance after authorized promotion. Full ten-suite feature and iPad/Mac
   journey acceptance remains requirement-by-requirement work.
