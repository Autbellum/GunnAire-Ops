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

## Native handoff and rollout

The native saved-estimate path now prepares customer/catalog prerequisites in the foreground, then persists an encrypted immutable `BillingNativePending` request and draft revision. It records `queueRequested` before its first POST. The client accepts only a server connection advertising `estimateQueueVersion: 1`; an older backend stops before a queue journal is created and never falls back to a direct device QBO write. The queue response must match the exact company, realm, environment, document, customer and original publication. `queued` means the backend accepted the job; it is **not** QBO confirmation. A lost response is reconciled through the original publication or exact job, and an existing reserved publication can receive the same job without a second provider create. An ambiguous response remains reviewable.

The estimate handoff caps selected sold items at 20. The repeated document/customer/item/payment membership checks use bounded targeted SwiftData reads; a complete 5,000-row Item and Customer mapping census runs twice in private `ModelContext`s through `Task.detached` before and after the queue POST, with a MainActor revision/session check on return. Confirmed estimate linking also checks provider-ID ownership twice off-main, and related ServiceCall activity uses an exact-ID fetch. A changed draft, unmapped or conflicting provider identity, lost bound device realm proof, expired business session, changed role/realm/connection, or oversized census fails closed.

This native bridge is still a **draft latency candidate**. The existing access policy intentionally reads every `AppUser` and `Technician` on MainActor to preserve normalized-email duplicate and crew-assignment semantics. `check()` also makes up to 20 sequential selected-item fetches there at each awaited boundary. Invoice and test-only direct-publication paths retain broader MainActor catalog/customer checks. A safe off-main access mirror and batched selected-item read remain release gates; no zero-latency claim is made for this PR.

Foreground startup and the Billing Review screen can poll the exact server job. A job needing review exposes an explicit retry of the **same** original proposal after renewed authority and proof checks; ambiguous provider outcomes do not auto-retry. The saved estimate and Billing Review show queue-requested/queued states across relaunch. Attachments are uploaded only after readback validates a QBO-confirmed estimate and its provider ID has been saved locally. Queueing sends no customer email or payment request.

Deploy and verify this backend capability **before** distributing a native build with the handoff. A native build ahead of a compatible server will refuse estimate queueing rather than silently route to a device QBO create. Frozen 0122 does not include this native bridge. Neither this branch nor its synthetic tests prove live QBO delivery, a deployed backend worker, or TestFlight availability. A saved estimate first created while the app is offline and then closed still needs a future foreground or bounded background wake to perform prerequisites and enqueue it. Apple background scheduling is opportunistic, so there is no deadline guarantee.
