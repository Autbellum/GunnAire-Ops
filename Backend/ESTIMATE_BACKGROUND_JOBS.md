# Server-owned QuickBooks estimate publication jobs

`POST /api/billing-publications/background-estimate` accepts the same immutable
`BillingPublicationRequest` as ordinary publication, limited to an original
Estimate create with at most 20 distinct sold items. It checks the current app
session, company, QuickBooks connection revision, customer and catalog mappings,
and billing authority, then atomically reserves the original publication and
its job. The response identifies a **pending** job; it does not assert that
QuickBooks accepted an estimate. Repeating the exact request returns the same
publication. `GET /api/billing-publications/background-estimate/{publicationID}`
returns its authorized status and original publication state.

The backend worker processes up to ten due jobs per wake, one at a time. It
uses `BillingPublisher.run`, which checks current session, role, grant and
proposal again, performs the complete original-document census, and consumes
the publication's single-use send permit before QBO POST. A lost response or
process restart can only read back the original marker; it cannot reset a
`sending` or `unknown` publication for another POST. A job lease may expire,
but the publication fence remains authoritative across competing workers.

For background work, the provider refuses a census larger than 500 documents
before POST. The queue rejects drafts with more than 20 distinct sold items
before reservation. These bounds make the backend operation finite; a larger
account's job enters a review state with no new provider write. A transient provider/storage error is retried at
most seven times after the first attempt, with increasing delays. Current
authorization or grant loss, ambiguous original evidence, and the safety
limits stop automatic work for review. The saved proposal and its original
publication remain intact.

This backend queue is not yet called by the iOS saved-estimate path or the
`BGAppRefreshTask` worker. It cannot, by itself, publish an estimate saved on
an offline or closed device. Integrating a native caller still requires a
bounded snapshot of an eligible saved estimate, mapped prerequisites, an
already bound device realm proof, an exact workspace/session fence, and local
readback of the confirmed provider ID. Customer email, attachments, catalog
creation and customer creation are outside this worker's contract. Deploying
the backend or merging this branch is a separate release decision.

## Native integration boundary at the 0122 source baseline

The existing foreground `QuickBooksBillingWorkflow.publishSharedDocument` is
not a safe refresh worker. It constructs the immutable
`BillingPublicationRequest` only after its context, catalog, tax and line
preparation; `QuickBooksBillingWorkflow.init`, `check`, and
`draftRevisionValues` fetch all `Item`, `Customer`, or `Payment` models and
filter them in memory on `MainActor`. Calling this path from a
`BGAppRefreshTask` would violate the bounded snapshot and UI-thread work
requirements. The foreground `AutomaticOutboundSync.recoverPending` has a
rotating 100-record estimate page, but starts a separate drain task and does
not provide an awaitable, cancellation-fenced, single-estimate handoff to the
refresh lifetime.

`BillingNativeJournalStore.device` holds an encrypted, scoped original only
after preparation. A newly saved offline estimate has no journal entry to
enqueue. Even for a prepared entry, the refresh needs a bounded, exact
revision check against the current estimate and relevant payments, a bound
`QuickBooksDocumentRealmProofStore` record, and current company, business
session, role and connection proof before it can POST the original request.
The current `draftRevisionValues` method is private to the foreground workflow
and obtains payments by fetching the entire table. Until a bounded reader and
shared revision validator exist, a background journal POST could publish a
stale draft. The native client also lacks a typed queue response and a
confirmed-result readback/settlement path. None of those gaps is silently
bypassed by this server-only change.

The smallest viable bridge is a foreground handoff **after** the existing
customer, catalog, tax and line preparation, at the point where
`publishSharedDocument` now calls `shared.prepare`. Before leaving that
method, it would need to persist the complete `BillingNativePending.request`
and `draftRevision`, record an explicit `queueRequested` phase *before* its
first transport suspension, and verify the bound realm proof and current
business, workspace lease, app session, role and connection. A new isolated
enqueue actor could then POST that exact immutable request to the queue; no
SwiftData model may cross into that actor. The actor must carry a captured
session/workspace generation and check it before and after transport. A
successful response must be validated as the same original scope and
publication, saved as `publicationID` with a `queued` phase, and presented as
**pending** rather than as a QuickBooks confirmation. If the response is lost,
only an idempotent POST of the same original request or a read of its known ID
may run. A 404, invalid response, changed identity or expired lease keeps the
local original for review; it must never fall back to direct QBO publication.

The foreground/restart workflow must then recognize `queued` separately from
`sending`/`unknown`/`confirmed`. It should read the exact server job on later
launches. A pending job leaves the local estimate unsynced and skips attachment
upload; a review job surfaces Billing Review. Only a confirmed publication may
use the existing read-only `recover` validation, save the provider ID and tax
result, settle the journal, and then consider attachments. Both
`AutomaticOutboundSync.publish` and the manual management caller currently
upload linked attachments after **any** successful workflow outcome, so their
callers also need the queued distinction. Before that handoff, replace the
full-table `Item`, `Customer` and `Payment` fetches in the relevant revision
and check paths with bounded identity-targeted reads. The refresh worker can
then inspect one persisted `queued` journal and await its exact status without
constructing or publishing a new proposal. This refactor spans the SwiftData
reader, journal phase, transport allowlist/client, result type and two UI
callers; changing only the transport would leave a stale-draft and premature
attachment path.
