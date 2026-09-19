---
name: gunnaire-perf-rules
description: The SwiftUI and SwiftData rules GunnAire Ops must follow so Command Center and every other screen stay responsive. Use when writing or reviewing any view, computed property, access check, or formatter in this app, and when a screen is reported slow. Each rule cites the place it was violated and what it cost.
---

# Performance rules for GunnAire Ops

This app holds every business record as SwiftData model objects under
NSPersistentCloudKitContainer mirroring. Two facts drive every rule below:

1. **Every CloudKit import merge invalidates every `@Query` on screen.** Command
   Center declares 23 root queries, so each merge re-runs its whole body. During a
   catch-up import (after install, after a long offline stretch, after any store
   reset) that is thousands of merges. Measured: 3,546 of 3,961 fetches in 45 s
   were `NSCKRecordMetadata` and `NSCKRecordZoneMoveReceipt`, zero main-context
   saves, body re-run back to back.
2. **Body cost is multiplied by that.** A body that costs 2 s is a 2 s freeze per
   merge. The fix is never "do less per merge"; it is "make the body cheap".

## Rule A: no formatter or locale construction on a hot path

`ISO8601DateFormatter()`, `DateFormatter()`, `NumberFormatter()`, and
`Locale(identifier:)` load ICU tables from disk. Construct them once (`static let`,
shared behind a lock if used off the main actor) and reuse them.

Violation: `CompanyCloudKitBinding.parseApprovalDate` built one per call, and every
role check reached it. 74.6% of all CPU on the iPad. Fixed in
`CompanyWorkspaceIdentity.swift` by `CompanyApprovalDateParser` (shared formatters,
last result remembered). Grep for `DateFormatter()` before shipping any change to
access, billing, or sync code; there are 57 constructions in the app.

## Rule B: a computed property that reduces a table is computed once per body pass

`suiteSnapshot` and `accountSnapshots` in `OperationsDashboardView` reduce every
customer, call, estimate, invoice, payment, and contract. Reading them from several
places re-runs the reduction each time. Take the value once (`let snapshot =
suiteSnapshot` at the top of the section) and pass it down; derive counts and totals
from the taken value, never from the property. Violation cost: 66.7% of samples
across `suiteSynchronizationSection` and `accountIntelligenceSection`.

The same rule applies to `OperationsAccessPolicy.capabilities`, `visiblePaymentIDs`,
`visibleInvoiceIDs` and the `dashboardPayments` / `openInvoices` / `overdueInvoices`
getters, which still recompute the policy independently (75% of what remained after
the two fixes). Memoize per body pass before adding any new reader.

## Rule C: `DisclosureGroup` content is built whether or not it is open

SwiftUI evaluates the content closure on every pass. Wrap expensive content in
`if isExpanded { … }` inside the group. Violation: both Command Center groups start
collapsed and still cost two thirds of the body.

## Rule D: access checks must be cheap enough to call thirteen times

`capabilities(email:users:)` makes about thirteen role checks; each goes
`activeRole` → `verifiedUser` → `authorizedContainer` → `lease.isValid`. Anything
added to that chain runs thousands of times per redraw. Keep it to comparisons over
already-parsed values. Never add I/O, parsing, or Keychain reads there; the session
memo (`memoizedSession`, 1 s) exists for exactly this reason.

## Rule E: relationship traversal inside a reduction is a fault per row

`payment.invoice`, `invoice.customer`, `serviceCall.customer` inside
`CustomerIntelligence.snapshot` fired 7,345 faults in one run. Prefer computing over
identifiers gathered once, and keep reductions off the main thread when they must
walk relationships (needs snapshot DTOs; SwiftData models are not Sendable).

## Rule F: any new view must not add an unbounded root `@Query`

The 23 in Command Center and 35 in ContentView are the invalidation surface. New
screens take bounded, predicated queries or receive already-loaded data. Zero views
use `fetchLimit` today; that is the direction, not the excuse.

## Rule G: measure before and after, in the right environment

Follow `gunnaire-perf-measure`. A change to this list without a measured before and
after on an authorized workspace is a guess, and the owner's standing instruction is
"Never guess."

## Evidence trail

Commits a825f29 (Rule A), c07070c (Rules B, C), dd57c8f (on-device recorder).
Traces from 2026-09-18 under the session temp directory `gunnaire-traces*`.
