# Remaining QBO legacy access work after 0124

Status: design only. No implementation or release claim. This audits source at
`8b4f80a` on 2026-10-02. The signed 0124 candidate is unchanged.

## Why the existing detached check cannot simply replace `validate`

`QuickBooksBillingAccessPolicy.validate` synchronously reads the complete
`AppUser` census on MainActor so that every spelling of a duplicate normalized
email participates in the denial. `checkOffMain` already creates independent
SwiftData contexts and returns a `Sendable` value mirror, but it rejects every
`context.hasChanges`. Document preparation, Gmail/QuickBooks communication
history, and billing review may legitimately have unsaved document changes.
Saving them merely to make the background read work would change the transaction.

The synchronous validator is also part of four different timing contracts:

| Path | Current synchronous point | Required conversion |
| --- | --- | --- |
| `QuickBooksBillingWorkflow.init`, `QuickBooksSyncRun.check` and `commit` | Capture run, check after provider awaits and before local save | Async factory, action-time async authorization before provider writes and local commits; retain a cheap synchronous identity/document fence between awaits. |
| `QuickBooksCustomerEmailWorkflow.init`, `validateSend`, `finish` | Check consent and authorization before attempt, before POST, after response and before recording history | Async factory and async send/history validation; preserve original communication and journal identity. |
| `GmailSendWorkflow.prepare`, `checkAsync`, `WorkspaceProviderOperation.transportFence` | Check business access after suspensions and immediately before Gmail transport | Async authorization in `beforeTransport`, with a final synchronous local stamp/record fence; never reuse a preflight result after another await. |
| `BillingPublicationReviewView` body and `BillingMilestoneInvoiceReview.allowed` | Render-time `validate` plus broad `@Query AppUser` observation | Async state for display only, invalidated on model/workspace changes. Reauthorize in the action handler before any mutation. Render state alone cannot be a write permit. |

`QuickBooksSyncAccessPolicy.validate` is another broad MainActor `AppUser` scan
for catalog administration. It needs the same treatment in a separate scoped
pass; removing only billing's census does not satisfy a whole-app latency claim.

## Proposed authorization boundary

1. Capture on MainActor only value inputs: normalized actor email, verified role,
   document kind and UUID, original model identifiers for document/customer,
   service-call UUID, company operation stamp, and the exact initiating
   `ModelContainer`. Run the existing cheap local document membership and
   workspace-generation fence before suspension. Never send a SwiftData model
   instance, `ModelContext`, or a closure that dereferences one to a detached
   task.
2. On a detached task, construct a fresh `ModelContext(container)` with
   autosave disabled. Read the complete user census, bounded at 5,001 rows and
   deny at the cap. Normalize *every* stored email, including noncanonical and
   inactive duplicates. Read technicians only for a field-technician job; use
   the existing lead/crew and exact customer comparison. Return a `Sendable`
   value mirror. Two equal reads, as in current `checkOffMain`, detect a change
   during collection; disagreement fails closed.
3. On MainActor immediately after the await, repeat the exact initiating
   workspace stamp, actor email, role, document/customer identity, and local
   document revision checks. Reject pending inserts/updates/deletes to
   `AppUser`, `Technician`, or `ServiceCall` in the initiating context: the
   detached context cannot see those changes. Do **not** reject unrelated
   unsaved document/history changes solely because `context.hasChanges` is true.
   The document workflow's existing snapshot/consent checks still decide
   whether those edits are acceptable. A newly inserted unsaved customer/job
   that cannot be established in the detached context must fail closed.
4. Make provider transport accept an async access preflight. Invoke the fresh
   detached mirror check as the last awaited authorization step immediately
   before a POST. Keep the synchronous `transportFence` for cheap initiating
   operation stamp, cancellation and local record identity checks. Check those
   again after the async authorization and before setting
   `mayHaveReachedProvider`. Repeat authorization after every provider await
   and before any local confirmation. Never cache an authorization mirror across
   a provider await or a new user action.
5. For direct QBO email, move the current synchronous `validateSend` callback
   to an async callback and keep its durable journal order: validate before
   `journal.acquire`, after read/reconcile, immediately before `/send`, and
   after the response. Do not acquire a new attempt after a changed grant.
   For billing runs, keep `QuickBooksSyncRun.check()` as a cheap synchronous
   run/stamp/document fence and require an async full authorization gate in
   `perform`, `receive`, and a new async local-commit wrapper. A synchronous
   callback that still performs a full census would defeat this design.
6. For review UI, remove the broad user `@Query` and synchronous computed
   validator. Async state may decide which review details are visible, but a
   stale state cannot enable a write; the button's async action must acquire a
   fresh permit. Invalidate state on document identity, workspace generation,
   relevant local SwiftData changes, and view disappearance. While checking,
   show a neutral pending state.

This preserves the existing *locally observable* action-time revocation model:
if a role or crew change has reached the device before the final check, the
write is denied. CloudKit delivery is eventually consistent; a local client
alone cannot guarantee immediate cross-device revocation before an unobserved
remote change. Any stronger promise requires server-side authorization at the
provider mutation boundary.

## Regression gates for the implementation

- `testNormalizedConflictingUsersDenyAtLastTransportFence`: insert a second
  noncanonical normalized email after preparation and before POST; assert zero
  POST requests and a retained original journal attempt.
- `testRoleOrCrewRevocationDuringDetachedReadDenies`: hold the detached census,
  change the local role or crew, resume it, and assert denial at the repeated
  local fence; cover technician lead and crew IDs, invoice and estimate roles.
- `testUnsavedDocumentEditDoesNotBecomeAnAuthBypass`: permit unrelated unsaved
  history/document fields only if the document snapshot/consent validator still
  passes; pending user/technician/service-call edits always deny. Do not force
  a save to authorize.
- `testChangedWorkspaceOrActorAfterAwaitDenies`: replace company generation,
  container or signed-in email during the background read; assert no provider
  request and no local confirmation.
- `testReplacementSameUUIDAndDuplicateRowsDeny`: swap a model with the same
  UUID or add duplicate document/customer rows while awaiting; fail closed.
- `testPostResponseRevocationLeavesReviewState`: revoke access after a provider
  response but before local commit; retain uncertain-write evidence and avoid
  reporting confirmed failure or silently retrying.
- `testUserCensusCapFailsClosed`: 5,001 rows deny rather than select an
  arbitrary subset; normalized duplicates remain visible up to the cap.
- Signed focused iPad suites must cover QBO billing/customer email, Gmail send,
  review UI and workspace transport. `generated/omni_runner.py` must compile
  the exact commit with zero warnings. A performance trace must show no broad
  AppUser/Technician fetch on Thread 1; tests alone do not prove latency.

Do not publish this as a completed zero-latency fix until those gates and a
physical-device trace pass. The 0124 signed release path should remain frozen
while this change is developed and validated in isolation.
