# Native job billing authority — September 7, 2026

Backend candidate: `2026.09.07.27`. This checkpoint connects real dispatch
edits to the assignment API introduced in `12382ae`. It does not claim the
remaining invoice/estimate button migration or full application acceptance.

## What is connected

- Add Job and Edit Job save an encrypted, original-workspace/office-account
  intent before committing the local job. Dispatch-board assignment and
  assignment-with-rescheduling use the same coordinator.
- A saved ordinary online crew change establishes server authority without
  requiring a separate office approval for every ordinary invoice. Crew members
  must resolve to distinct active business accounts; office roles retain their
  separate server permissions. Missing crew accounts, cancelled jobs, no-access
  visits and non-work events cannot accidentally retain the former crew grant.
- The existing job Overview has one Field Billing link, not a new top-level
  workspace. Review shows saved crew and server access, explicit conflict
  confirmation, read-only lost-response recovery, and a native back action to
  the same job. It does not expose raw JSON, tokens or an account-email footer.
- The authorized CloudKit workspace resumes its original account's pending
  queue on entry, foregrounding and a realm change. Signing out does not delete
  saved work or replay another dispatcher's queue. A first offline edit without
  a previously observed connection needs explicit office review after restart.
  New offline jobs can use the business connection already observed on this
  device; they still require a zero server revision and reject any reconnect.
- Job-save failure no longer dismisses the Add/Edit form or starts Calendar
  follow-up. Edit rollback restores its own fields, technical readings,
  agreement due date and new activity records without rolling back unrelated
  SwiftData changes. Dispatch-board failure restores its original assignment.
- A queued authority change records job activity. Existing history-aware
  deletion preserves that job; use cancellation to end access rather than
  deleting the job and losing its recovery context.

## Contract and concurrency

`GET /api/job-billing-assignments` returns `assignment` (possibly null) and
`connectionRevision`, an opaque 64-character lowercase hexadecimal epoch.
Assignment POSTs now require that exact epoch in addition to the existing
scope, job/customer, crew, enabled, expectedRevision and operationID fields.
Both save and read responses include the epoch. It is a separately derived
hash, not the internal grant fingerprint or a provider credential. Token
refresh preserves it; a new authorization grant changes it.

The server rejects missing/malformed epochs and returns a conflict when the
original epoch no longer matches. This includes a never-sent first assignment
with revision zero: it cannot silently adopt a reconnected account.

The native journal is atomic AES-GCM ciphertext with authenticated scope and a
device-only Keychain key. It lives under Application Support/JobBillingDispatch-v1,
has hashed scope filenames, is excluded from backup and uses file protection
until first user authentication. Corrupt data, wrong scope, unavailable keys,
invalid identities and bounded-size violations fail closed without deleting or
resetting the old file. No stored SwiftData/CloudKit model schema changed.

Prepared edits must match a fresh committed ModelContext before any server
request. Confirmed-save marker failure leaves a recoverable prepared intent;
it does not falsely report that the job failed to save. Unsent edits coalesce
while retaining the original baseline. Possibly-sent edits preserve immutable
request evidence; a newer local crew change does not replay the old request.

Known unchanged assignments may retry the same operation ID and payload
against the same connection and expected revision. This is an idempotent
assignment mutation, not an accounting/payment retry. Read-only recovery first
recognizes an already accepted or identically approved newer assignment.
Any different newer assignment needs human confirmation. That confirmation is
bound to the displayed server revision and local saved crew; another change
between review and confirmation is rejected again, not overwritten blindly.

Offline revocation is not instantaneous: other devices retain the last
server-confirmed access until the queued change is accepted. The UI says so.
Queues are device-local; CloudKit continues to own job records and activity.
This implementation does not establish independent staff Apple-account sharing
or signed cross-device convergence.

## Verification

Final-source acceptance passes with zero failures or skips:

| Gate | Result |
| --- | --- |
| Mac Catalyst arm64, complete logic | 1144/1144 |
| M5 13-inch iPad / iOS 26.2, complete logic | 1144/1144 |
| Five selected iPad interface journeys | 5/5; 1149 total with logic |
| Focused assignment/publisher/adapter backend | 103/103 |
| Complete Backend / Tools | 319/319 and 37/37 |
| Unsigned optimized Mac Release | arm64 and x86_64 verified by lipo |
| Workflow validation | Both YAML files pass actionlint |

Twenty-four new dispatch logic tests cover saved-model gating, original scopes,
connection/revision conflicts, offline creation and reassignment, lost responses,
role loss, changed/deleted/duplicate jobs, missing crew accounts, nonbillable
visits, coalescing/uncertain older operations, narrow edit rollback and protected
encrypted-file recovery. The UI set covers job-access confirmation/return,
original-access recovery, Invoice launch, simple Mail and deletion protection.
All three final job-review/recovery PNGs were visually inspected: unclipped
content, explicit pending versus confirmed access, original technician names,
native back navigation, and no account-email footer or raw provider details.

Evidence root:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Native Job Billing/`.
It contains `MacAcceptance.xcresult`, `iPadAcceptance.xcresult`, final and
diagnostic logs, `CrewReview/` and `Recovery/` screenshots, and source hashes.
Final logs: `gunnaire-job-dispatch-mac-final-v4-20260907.log`,
`gunnaire-job-dispatch-ipad-final-v5-20260907.log`, and
`gunnaire-job-dispatch-release-final-20260907.log`.
The final Release executable SHA-256 is
`aaabf41e572ec521af9e93ccaa02fe3b5bce1648d1110d7c5855000877885de2`.
Project manifest SHA-256 remains
`52ecaabdb59c9d554d286f448a121eecd5a319afd6961bd9de62c3c075b315f7`.
Mac UI execution remains a separate unresolved host gate; no new Mac UI or
signed physical-device acceptance is claimed. The pre-existing external Metal
toolchain search-path warning remains. The candidate hosted workflow adds the
two new UI journeys to the prior fourteen; fresh-head hosted checks remain
separate from these five local journeys.

Historical focused acceptance before the UI fixture: 41 native logic tests pass
(20 billing client and 21 dispatch tests). Focused server acceptance is
103/103; full Backend is 319/319 and Tools is 37/37. The final-source results
above supersede these narrower native checks.

The initial backend test used a nonexistent access-token column; it was
corrected to rotate the actual refresh-token ciphertext. Initial native
compilation found a default closure's actor isolation, two missing inner `try`
expressions in test macros, and an extra closing parenthesis in the UI fixture.
Those diagnostic logs are retained; failed attempts are not counted as passes.
The first wider iPad run passed all 1143 logic tests and four of five UI
journeys. The conflict fixture omitted its technician's business account, so
the app correctly kept access off. The fixture now provisions that test-only
account, and both UI journeys assert the actual saved technician name. The
earlier read-only UI pass for an off state is not counted as field-access proof.
Subsequent UI assertions were corrected to inspect the labeled crew value and
the stable confirmation-button identifier. iPad exposes a nested duplicate
accessibility button wrapper; the test targets the first matching wrapper for
that same exact action. No permission, conflict check or assertion of the
confirmed technician was removed to make the test pass.
One Mac recheck was started before the existing Release process finished and
failed on the shared build database lock. That run is retained and superseded
by a serial final recheck; it is not treated as an application failure or pass.

Prior published head `12382ae` passes all four hosted jobs:
[native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34140905031) and
[backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34140905066).
That proves the preceding HTTP/client checkpoint, not these new source changes.

Apple references checked in Safari for this implementation:
[navigation hierarchy](https://developer.apple.com/design/human-interface-guidelines/sidebars),
[authenticated AES-GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm),
and [protected atomic file writing](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotectionuntilfirstuserauthentication).
The interface guidance favored keeping this low-frequency review in the job's
existing navigation hierarchy. CryptoKit guidance informed authenticated
encryption rather than merely encoding local crew data.

## Remaining full-goal work

Existing Invoice/Estimate buttons still use the prior retained native workflow.
Structured origin/service tax-address review, scalable shared legacy mappings,
publication approval/recovery handoffs and server-only billing dispatch must
be completed together before cutover. Field-created items and sold prices must
remain intact; this is not an office-only substitute for technician invoicing.
Other schedule creation/import pathways can open job access review but are
not all automatically staged by these three edited entry paths. Cross-device
server-owned job lifecycle, finalized/signed/change-order authority and legacy
deletion reconciliation still require implementation and verification.

The ten-competitor inventory remains a feature-coverage map, not proof of
flawless workflows. Complete ledger/payment-event and bank-settlement history,
server payment sending and credential containment, durable Mail drafts/outbox
and received-message/job/file linkage, Google coordination, supplier access,
signed CloudKit/offline convergence and independent staff Apple accounts,
Mac UI test-host qualification, approved physical-iPhone Tap to Pay/Handoff and
distribution/provider production acceptance remain open.

Review/back up/deploy the backend before distributing a native candidate that
uses this contract. Preserve assignment, billing, payment and encryption data.
Old code ignoring shared locks is not a safe financial rollback. No merge,
deployment, signing/entitlement change, CloudKit promotion, physical install,
customer send or live accounting/payment mutation was performed here.
