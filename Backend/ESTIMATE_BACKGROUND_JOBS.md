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
