# QuickBooks sync workflow lifecycle

## Current-source revalidation — September 7, 2026

Read-only inspection of review head `442e9d7` confirms a concrete remaining
event-reconciliation dependency. `BackendQuickBooksWebhookEvent` retains entity
type, entity ID, operation and occurrence time. However,
`QuickBooksManagementView.syncAllQuickBooksData` passes only `events.map(\.id)`
into resource sync, and `finishQuickBooksResourceSync` acknowledges every
captured ID when the overall resource/import failure list is empty.
`QuickBooksLocalSync.importSnapshot` accepts six resource arrays, not event
operations or per-event outcomes. Its item loop also deliberately preserves
pending local catalog changes and ambiguous mappings instead of applying them.
These protections are useful, but a generic successful refresh does not prove
that each queued entity change has been reconciled.

The next implementation must retain event identity and operation through the
captured run, produce explicit per-entity reconciliation evidence, and acknowledge
only the original events whose effects are proved. Unsupported, missing,
deleted/voided, ambiguous or still-under-review changes must remain pending with
an actionable explanation until an appropriate recovery/reconciliation path
handles them. Deletion handling must preserve sold-document history rather than
erase local invoices or reprice their snapshots. Mixed-event, stale-event,
role/realm-change, failed-import and partial-success tests are required.

This is a source-observed gap, not a new implementation or a claim about live
provider data. Current Intuit event/entity semantics must be verified against
primary documentation before changing provider requests or choosing deletion
and ordering rules. No live accounting read/write or event acknowledgement was
performed during this review. Complete item/entity synchronization, shared
server authority and physical multi-device acceptance remain required.

September 7, 2026. Review-branch implementation checkpoint; not a production
deployment or full application acceptance declaration.

## Observed gap and retained identity

The QuickBooks Management sync previously scheduled token refresh and each
resource separately. Individual HTTP requests/pages were guarded, but a new
resource could capture replacement credentials after suspension. Its resource
arrays, local import, stored-card references and detached webhook follow-up
did not share one run identity. A second sync could also reuse screen state or
let an older completion clear its progress.

The provider layer now offers a synchronously captured workflow handle.
QuickBooks Management captures it at the initiating action, before scheduling
its Task, and keeps it through token readiness, webhook reads, every
accounting/Payments resource, accounting mappings, local model saves and
acknowledgement. Captured handles retain their API owner, connection generation,
realm, environment and verified workspace operation.

The implementation uses the existing task-local provider scope. Swift's
[task-local proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0311-task-locals.md)
defines propagation across task suspension/child work; explicit handles cover
the scheduling boundary and re-enter the correct scope. These are application
security rules, not claims that Intuit validates GunnAire's native workspace.
The current Intuit interactive OAuth/webhook reference pages did not expose
usable content during this check. No provider endpoint, scope or webhook wire
contract changed.

## Corrected behavior

- A new run invalidates its predecessor. Late callbacks cannot apply records,
  commit models, record resource success, acknowledge captured events, or
  finish/clear a newer run. Leaving the screen cancels its run.
- The run's lifetime and access checks are composed into the provider operation,
  so later retries/pages stop after cancellation or access loss, not only at
  the final import. Enclosing uncertain-write evidence is preserved.
- Model saves use the captured context. In production its container must still
  be the authorized CloudKit business container. Current saved staff records
  must all agree on an active administrator and the valid server-verified
  workspace lease must also identify an administrator. The legacy primary-email
  administrator shortcut is not used for this sync authorization check.
- Resource success belongs to the run, not retained view rows. Failed
  resources cannot contribute cached arrays. Stored-card fanout requires
  current-run customers; saved method references require an exact, unambiguous
  provider customer identity. No same-name fallback is used for these links.
- Accounting mapping refresh revalidates before caching/publishing, and
  request IDs prevent an older refresh from overwriting a newer result or
  clearing the newer loading indicator.
- Identical saved-credential reloads no longer invalidate the connection.
  A changed saved token/realm/environment/scope or explicit reconnect still
  invalidates it. A temporarily unreadable saved session clears in-memory
  access without deleting Keychain data.
- Last-success timestamps use company/realm/environment-specific keys.
  Unscoped legacy timestamps are left intact but are not presented as evidence
  for the current business.
- The existing workspace remains. Progress/success wording is shorter;
  detailed resource warnings remain available. A stopped run clears transient
  provider rows, not saved business records. No stored SwiftData field,
  CloudKit schema, entitlement, signing setting or project manifest changed.

## Verification

The first focused run passed 31 tests across the new lifecycle and existing
payment-workflow suites. The expanded run then exposed five error-classification
assertions: cancellation/role loss was being replaced by a generic provider
connection error. The requests and commits were stopped, but the specific
recovery outcome was wrong. The lifecycle now rechecks and restores that
specific outcome before returning to the caller.

Final current-source acceptance on Xcode 26.6 (17F113):

- M5 13-inch iPad Simulator, iOS 26.2: **876/876 logic tests and 6/6
  focused interface journeys pass** (882 logical tests, 890 parameter-expanded
  executions), with no failures or skips.
- arm64 Mac Catalyst: **876/876 logic tests pass**, with no failures or skips.
- An unsigned optimized universal Mac Catalyst Release succeeds;
  lipo verifies both arm64 and x86_64. The existing external Metal-toolchain
  linker search-path warning remains; it is not an app compile failure.
- Interface journeys cover direct Invoice launch, simple Mail actions,
  current statement generation, billing-identity review, unconfirmed-balance
  Reports → Invoices → QuickBooks, and statement review → Invoices.
- Both GitHub Actions workflow files pass actionlint; the source copies match,
  the diff is whitespace-clean, and the project manifest hash is unchanged.

The runs use the GunnAire Ops scheme, serial execution and
CODE_SIGNING_ALLOWED=NO. The full commands are recorded in the acceptance logs.
Retained evidence under
/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/:
QBO Sync Lifecycle iPad Acceptance.xcresult,
QBO Sync Lifecycle Mac Acceptance.xcresult, matching acceptance logs, and
QBO Sync Lifecycle Universal Release.log.

The dedicated lifecycle suite has 27 tests, including actual injected QBO
query transports, an in-memory multi-resource import, callbacks resumed after
replacement/revocation, pagination interruption, ordinary-resource recovery,
cancelled/overlapping runs, exact role checks, unchanged credential reload,
changed session invalidation, and controllably delayed mapping responses.
No test reads/writes live credentials or calls a live business endpoint.

The prior published head ba5617f passes both hosted native jobs and both
Backend matrix jobs: [native run](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34091222075)
and [backend run](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34091222082).
Those results establish the earlier balance/QR checkpoint, not this subsequent
workflow lifecycle change.

## Remaining full-goal requirements

Follow-up: Management catalog approval/retry, comparison and both reviewed
reconciliation directions are addressed in
[QBO_CATALOG_WORKFLOW_LIFECYCLE.md](QBO_CATALOG_WORKFLOW_LIFECYCLE.md).
Its acceptance is distinct from this resource-sync checkpoint; the separate
BillingDocumentsView catalog/document publication chain remains unqualified.

This checkpoint covers the active QuickBooks Management resource-sync path,
not every multi-step integration in the application. Customer/vendor/catalog
publication, attachment delivery, Google archive/calendar orchestration and
other retained-model callbacks still require equivalent end-to-end audits.
The unused legacy ContentView.fetchAndSyncQuickBooksData helper has no current
call sites; it is not evidence that another active sync path was qualified.

The webhook queue still needs event-specific proof for deleted/voided or
reallocated records and unsupported entity changes; acknowledging a completed
resource refresh is not a full tombstone/dated-ledger reconciliation algorithm.
The provider and backend are not an atomic shared snapshot, and the UI checks
do not establish a server-owned provider broker. Remote role changes depend on
workspace/role refresh and the existing bounded offline lease; this is not
instantaneous offline revocation.

Historical statements/ledger evidence, changing payment allocations, ACH
settlement/returns, administrator conflict-resolution workflows, signed
CloudKit multi-device/offline convergence, production provider approval,
iPhone Tap to Pay/Handoff acceptance, distribution signing and remaining
ten-suite feature acceptance all remain required. No merge, deployment,
CloudKit promotion, real accounting write, charge, customer message, signing
change or physical-device install occurred.
