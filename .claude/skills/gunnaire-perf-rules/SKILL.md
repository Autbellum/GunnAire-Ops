---
name: gunnaire-perf-rules
description: The SwiftUI and SwiftData rules GunnAire Ops must follow so Command Center and every other screen stay responsive. Use when writing or reviewing any view, computed property, access check, or formatter in this app, and when a screen is reported slow. Each rule cites the place it was violated and what it cost.
---

# Performance rules for GunnAire Ops

## The owner's standing policy (2026-09-19)

Eric set these four as policy after the Command Center watchdog crashes. A
violation is a defect, not a style note. Cite the number.

1. **Never** perform JSON decoding, SwiftData saving, or API networking (QBO,
   Google, CloudKit, Apple) inside a SwiftUI `body` or on the `@MainActor`.
2. Every networking manager uses `async/await` and runs **off** the main actor,
   touching it only to set `@Published` properties.
3. Audit every `@StateObject` / `@ObservedObject` initializer; heavy loads go in
   `.task { }`, never `onAppear`.
4. Heavy `ForEach` loops use `LazyVStack` / `LazyHStack` or explicit identifiers.
   Command Center's root is an eager `VStack` in a `ScrollView`
   (`OperationsDashboardView.swift`, `body`): rule 4 violated at the top level.

Rule 1 in SwiftData terms: `@Environment(\.modelContext)` is main-actor-bound by
design, so *every* save through it is on main. For bulk sync writes the fix is a
background `ModelActor`, not a smaller save.

## The owner's launch and CloudKit policy (2026-09-19)

5. No synchronous URLSession, CloudKit container, or OAuth state calls in
   `AppDelegate`, the `@main` App struct, or an initial view's `init()`.
6. `accountStatus()` is never called synchronously or awaited inside anything
   blocking main during initialization.
7. Persistent-store loading must not block the UI; splash while it completes if
   migrations are heavy.
8. Google and QBO token validation runs in detached background Tasks
   (`Task(priority: .userInitiated)`).

Scan of 2026-09-19 against 5–8: `App.init` and `didFinishLaunching` make no
network, CloudKit, or OAuth calls; every `accountStatus()` is awaited in an async
function (`GunnAireCloudKit.swift:60`, `CompanyWorkspaceHost.swift:204` with a 20 s
timeout). `ModelContainer` is built synchronously in `App.init`; measured launch to
first frame was 0.7–1.2 s, so it is not where the freeze is. The startup offender is
`ContentView.onAppear`, which runs five functions that fetch and save on the main
actor at first appearance (`collapseCloudKitUserDuplicatesIfNeeded`,
`cleanupCalendarCreatedCustomersIfNeeded`, `refreshGoogleAccountIdentityIfNeeded`,
`retryPendingSharedCompanyDocumentUploadsIfNeeded`,
`retryPendingCustomerCommunicationUploadsIfNeeded`). The QuickBooks resource sync
(`QuickBooksManagementView.syncAllQuickBooksData`) runs as `Task { @MainActor }`
and writes through the main context: rule 1 violated for sync; it runs on visits to
QuickBooks Management, not at launch.

## Rule H: this project defaults every unannotated type to the main actor

The app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Swift 5 mode,
approachable concurrency). `GunnAireBackendService`, `AppAccess`,
`OperationsAccessPolicy`, `CustomerIntelligence`, `FieldFormJSON`, every static
constant: all main-actor-isolated unless marked `nonisolated`. Two consequences:

- Anything a background actor (`ContentStartupMaintenance`, a detached task) reaches
  must be marked `nonisolated`; the compiler reports each missed one as a warning
  that cascades one level per build. Mark pure helpers and immutable `static let`s
  `nonisolated`, never `nonisolated(unsafe)` on mutable state.
- The backend service's synchronous work (request building, JSON decoding of every
  QuickBooks, Google and workspace response) runs on the main actor today. That is
  rules 1 and 2 violated at the root and the next structural item; it is a large
  change because the service reads main-actor singletons inline.

## What the launch path does now (2026-09-19, build 2026091616)

`CompanyWorkspaceAccessController.unlock` is `async`; the store identity read and
the `ModelContainer` open run on a detached task, and every resumption re-checks
the generation and session. The user reconciliation and template seeding stay on
the main context (a handful of rows; the tests pin that an unchanged user never
saves). `ContentView.onAppear` holds layout state only; token loads and the
maintenance run in `.task`, with the full-table fetches, user-duplicate collapse
and upload retries on `ContentStartupMaintenance` (`@ModelActor`). The recorder
reads and writes its file off main. Debug build: 0 warnings (was 22).

## What the device recorded (2026-09-19, TestFlight 2026091612, real data)

73 stalls, all Command Center, 17–26 s each, back to back; two crashes were
`0x8BADF00D` watchdog kills ("failed to terminate gracefully after 5.0s",
"scene-update watchdog transgression"). The crash class is main-thread
unresponsiveness, not memory. Pulled over the cable with
`xcrun devicectl device copy from --domain-type appDataContainer
--domain-identifier com.gunnaire.businesssuite --source "Library/Application
Support/PerformanceDiagnostics-v1/events.json"`; `occurredAt` is seconds since
2001-01-01.

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
getters. The worst case, proven by the symbolicated 2026-09-19 crash logs of build
14: `outstandingBalance(for:)` read `dashboardPayments` inside the `openInvoices`
**sort comparator**, so every comparison re-ran the payment policy (two capability
passes, thirteen role checks each) and walked every payment's relationships. Since
build 16 every such getter reads through `OperationsDashboardPassMemo`, cleared at
the top of `body`, and balances come from one `[UUID: Double]` per pass. Any new
getter on that view goes through the memo; any new sort key is precomputed.

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
