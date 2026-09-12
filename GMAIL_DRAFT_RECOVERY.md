# Mail draft and interrupted-send recovery

Candidate: September 7, 2026. This extends the existing simple Mail interface
and shared Gmail send coordinator. It is not the server-owned cross-device
outbox, a CloudKit synchronization claim, or production release acceptance.

## User journey

Mailboxes now includes **Drafts on This Device**. Draft rows show only the
recipient, subject and, when needed, a short instruction to check Sent.
Search filters these saved drafts without changing the provider mailbox.

The composer autosaves bounded incomplete input after a short editing pause and
flushes on backgrounding, explicit Save Draft and Send. A compact save status
distinguishes saved work from pending or failed persistence. Cancel offers
Save Draft, Delete Draft or Keep Editing. On iPad, the native confirmation
popover's outside-tap dismissal implements Keep Editing; it does not show the
iPhone-style cancel row. Interactive sheet dismissal cannot silently discard
work. Explicit deletion need not save invalid or oversized input first.

Reopening retains original text, every attachment byte, reply references and
explicit customer/job/invoice/estimate/service-agreement context. It uses the
current original-account access check, not a serialized credential or closure.
Business drafts retain stable contact, consent and linked-work values. Changed
linked work must be reviewed at the original record before a new message is
prepared; a fresh process cannot silently approve a different invoice snapshot.

An interrupted or uncertain send reopens read-only. **Open Sent** checks current
original-draft access and hands off to the actual Sent mailbox without another
send. A confirmed rejection permits explicit editing/retry. Gmail acceptance is
not recipient delivery, and a rejected verification GET cannot reverse the
accepted POST into permission to send again.

## Durable state and authority

- Scope is the verified company, backend origin, business actor and matching
  Google mailbox. Account/workspace changes clear the presentation, not saved
  data. Current role, model-container membership and business/assignment access
  are checked when drafts are opened, saved or used to send.
- Each draft has one stable ID and RFC Message-ID. Revision comparisons stop
  stale windows overwriting newer content or reactivating a completed attempt.
- `editing → sending` is durably saved before provider contact. The same live
  dispatch owner may record confirmed acceptance, definite rejection or
  uncertainty. A new process cannot turn a saved `sending` state into editable
  work by claiming a rejection. If outcome persistence fails, the saved lock
  remains. UI sends and generated-document sends use this common coordinator;
  production defaults cannot skip the journal. Fixture injection is isolated.
- Explicit deletion clears the draft content and leaves a compact tombstone.
  Accepted/removed records cannot be resurrected by a stale window and do not
  consume the active-draft quota. Historical records remain bounded separately.
- Files are atomic AES-GCM envelopes with distinct authenticated summary/body
  sections, bound to exact account scope and draft ID. Listing reads only the
  small encrypted summary, not every message attachment. Opening verifies the
  complete body and matching summary/revision before exposing the composer.
- Keys use the existing device-only Keychain policy. Files use protected writes
  and are excluded from backup because the encryption key is device-only.
  Missing keys, malformed files and failed writes do not erase or replace the
  collection with an empty store. No draft content or attachment filenames are
  stored in plaintext preferences, logs or an unprotected list index.

The application bounds drafts to 2 MiB of body text, existing 50-file/25,000,000
decoded-byte attachment limits, 512 active records per scope and 65,536 total
retained records. Invalid/incomplete addresses can be saved; the existing MIME,
header, recipient, consent and linked-business checks remain required for Send.
These are application storage limits, not Google service-limit claims.

## Qualification

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Mail Draft Recovery/`.

The initial focused Mac result passes 54 logic tests and the pre-index full Mac
result passes 1216 logic tests. The initial iPad run passes 54 logic tests and
two of three restart journeys. The attachment journey stopped at a harness
assumption that iPad exposes the cancel-role row; its retained accessibility
tree proves the native popover and dismissal region. Initial compile failures
in fixture actor annotations and throwing test macros are also retained.
None of these failed runs is represented as passing acceptance.

Final-source acceptance passes **1219 logic tests per native platform** and
**10 selected iPad journeys** (1229 total in `IndexedIPadAcceptance2.xcresult`,
zero failures/skips). Mac logic evidence is `IndexedMacAcceptance2.xcresult`.
The 25 added logic tests include authenticated-summary and active-quota checks,
restart recovery, identity, missing keys, stale windows, corruption, original
business snapshots and provider dispatch. No assertion is skipped or marked
continue-on-error. An intermediate indexed run stopped at an invalid test
element accessor; the corrected accessor uses the observed popover dismissal
region and the final attachment journey passes through save, relaunch and
explicit deletion.

`UniversalMacRelease.xcresult` passes the unsigned optimized Release build;
`lipo -verify_arch arm64 x86_64` succeeds. Only the two existing optional
Metal-toolchain search-path linker warnings remain. The executable SHA-256 is
`1e9ae409001d45a37fb2c7665906e65f292dbd382b77d5661eec4db9bdccdf52`.
The new draft fixture-control strings are absent from this Release executable.
Backend passes 366 tests and Tools passes 37. Both workflows pass actionlint.
`SOURCE_SHA256.txt` identifies the seven changed Swift source/test files and
unchanged project manifest; the review clone matches these hashes.

Fifteen final PNGs are retained. Seven representative screenshots were visually
reviewed: recovered draft/attachment, recovered uncertain send with Open Sent,
compact mailbox menu, simple compose, simple Inbox, retained failed-send draft,
and draft-only attachment removal. They show legible natural controls, no raw
provider/MIME panel and no account-email footer. The ordinary compose screenshot
captures the visible autosave interval; the dedicated termination test waits for
the saved state before killing the app.

Preceding published head `64e3fce` passes all four hosted jobs:
[Native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34163116116) and
[Backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34163116154).
Those results do not qualify this new Mail candidate's exact head. Its workflow
adds the three restart journeys, bringing hosted iPad selection to 27.

## Remaining requirements

Cross-device/provider drafts, server-owned Google OAuth/token containment,
immutable shared send intents, exact provider read recovery, shared history
save recovery, received-mail/customer/job/document archival and delivery/bounce
outcomes remain required. Device-local encrypted files are not a substitute for
the server/CloudKit business data model. The last edits before an abrupt kill
can still be within the visible autosave interval; confirmed autosaves and
pre-send locks are the states qualified by restart tests. Large-draft save/list
latency and disk-pressure behavior need physical-device qualification.
Local revision transitions are serialized within the app process; independently
running Mac processes and multiple devices still need shared server authority.

The unchanged full-suite goal also retains complete QBO sync/reconciliation,
independent staff CloudKit sharing, signed/offline physical multi-device proof,
approved iPhone Tap to Pay/Handoff, supplier onboarding and all remaining
competitor-suite/provider/distribution acceptance gates. No merge, deployment,
live email/accounting/payment, signing, entitlement or CloudKit promotion is
part of this source checkpoint.

## Primary platform reference

Apple's [protected data-write option](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotectionuntilfirstuserauthentication)
was reviewed in Safari on September 7, 2026. It is supported by the existing
iPadOS/Mac Catalyst targets. This implementation keeps the project's existing
deployment targets, main-actor isolation and Keychain accessibility policy.
