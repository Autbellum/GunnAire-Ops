# Confirm an existing staff field update from another owner device

## Shipped boundary

An owner can now choose **Confirm Existing Update** in the secondary Field
updates review when their other office device prepared the original claim and
the original value is already present in both saved local data and the current
company source. This does not apply a field, transfer a claim, or authorize a
different owner account. It does not prove physical CloudKit convergence.

POST `/api/workspace/field-edits/{commandID}/confirm-observed` uses the closed
`staff-owner-field-observation-v1` contract: tenant scope, original command and
claim IDs, stable observation ID, observer store, exact source revision/value.
The current authorized owner must match the original claim owner; the observer
store must differ. An unfinished claim whose value is absent cannot be taken over.
Original staff revocation does not prevent acknowledging already-published work.

The source and original command/receipt never change. The original application
only transitions from prepared to published; its operation, store, author,
preparation time and expected value remain intact. The encrypted witness records
the exact observer request and published application. Both writes and the audit
event share one database transaction. Encryption failure leaves both unchanged.
Exact retries return the original witness even after later office changes, but
always require current owner/tenant authority. Corrupt encrypted state fails
closed and is never overwritten. Clock regression cannot create invalid prepared
or published receipts in this endpoint or the sibling prepare/confirm endpoints.

## Native recovery and limits

- The action compares a frozen review and saved local field, fetches current
  detail again, and checks the saved value after that reply. Unsaved office drafts
  suppress the action. No model-apply function is invoked, including by the UI
  wrapper (which does not trigger unrelated automatic applications).
- An encrypted device-local original request is saved before POST. Its ID/body
  survive restart, reply loss, and partial local-write failures. The existing
  bounded sync loop retries durable observations, not fresh automatic claims.
- An immutable local witness archive is durable before pending cleanup. If the
  original claim was confirmed elsewhere, authenticated published application
  evidence can close the pending request without fabricating an observation
  receipt for a request the server never accepted.
- A stale source revision requires explicit new review. The old exact request is
  archived with a monotonic source-revision supersession fence before replacement.
  Supersession and publication evidence have separate immutable keys, so an
  interrupted supersession followed by publication cannot strand the original.
- The journal is backward compatible with version 1 and optional observations;
  at most 32 observation intents, 8 processed commands per pass, existing 7 MiB
  request / 32 MiB response / 64 MiB journal limits. Unknown fields remain rejected.

## Verification and release gates

Real isolated HTTP tests cover authorization, exact retries, revision races,
encryption rollback, corrupt witnesses, Keep Office conflicts and clock regression.
A captured Python HTTP fixture is decoded/validated by native tests. File-backed
SwiftData tests cover no-reapply, saved/unsaved review fences, durable boundaries,
reply loss, relaunch, revocation, stale review and confirmation elsewhere.

Qualification evidence: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Owner Publication Recovery.zQw2pF`.
Only background shell/API checks, headless unit tests and unsigned release builds
are used. No screen capture, browser UI, live customer writes, deployment, signing,
push or merge is included.

Full goal stays ACTIVE. Unapplied cross-device takeover/release requires an actual
old-device/private-store write fence; a server-only lease cannot prevent an old
offline device from applying. Independent-account physical CloudKit sharing,
production signing/schema, remaining field/HVAC workflows, QBO/Google/vendors,
payment acceptance, parallel UI qualification and the full requirements audit
remain separate gates. Never delete journals or claim production readiness from
these local tests.
