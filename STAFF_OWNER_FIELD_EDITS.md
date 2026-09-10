# Owner application of staff field edits

## Implemented boundary

An authorized owner now receives original staff commands in the existing owner
workspace sync. Eligible operations-only scalar edits update the actual saved
model field, then use the existing full-source publisher. The field-update UI
is a secondary review section, with a record title and expandable value comparison;
it does not expose raw API payloads or put technical data in the main navigation.

`recorded` remains the original staff acceptance receipt. `prepared` is a separate
owner-device claim, not proof of a save. `published` proves that the requested
field reached the company full source; it does not prove physical CloudKit
convergence, a QuickBooks update, or a successful payment.

## Safety and recovery

- Owner-only GET `/api/workspace/field-edits` pages at most 50 scanned originals.
  GET `/{commandID}` returns the original base, request, author/time, eligibility,
  current source field and separate application. POST `/{commandID}/prepare`
  exclusively claims the immutable operation; POST `/{commandID}/confirm` checks
  the source value. Exact paths, closed schemas and current company authorization
  apply throughout. Staff cannot use these endpoints as owner access.
- The server encrypts claims and originals. A legacy command's base is recovered
  from its original authenticated selection, never today's office value. Duplicate
  operation IDs, different owner devices and malformed receipts cannot silently
  replace or hide an original.
- Automatic application requires the saved local field, current source field and
  original base to agree. Initial conflicts need a fresh, explicit comparison and
  confirmation. A newer change invalidates an open review.
- The owner saves an encrypted local intent before claiming or editing. The
  exact original operation survives restart, interrupted local writes, failed
  model saves, and lost HTTP replies. At most eight commands run per pass, with
  a durable rotating cursor; at most 32 applications may be locally pending.
- The model writer reads disk through a fresh context, rejects unsaved office
  drafts, and reserves the otherwise-clean main context synchronously to write
  one typed field. This refreshes existing model references without an extra
  UI-refresh save. History identifies the original command as transaction author.
  Error rollback is allowed only when the complete known pending change set is
  that scalar and the codec excludes no attributes; unexpected drafts are kept.
- After current authority changes, no new model write is allowed. Previously
  applied and published work can still be acknowledged by its original owner
  after staff revocation, without restoring that staff member's access.
- Resource limits remain bounded: 7 MiB owner requests, 32 MiB owner responses,
  64 MiB encrypted-journal plaintext cap. These accommodate JSON escaping and
  repeated original/current/claimed values. Staff command requests remain 8 KiB;
  their receipt readers allow 32 KiB for escaped Unicode.

## Remaining release requirements

- A prepared claim with a later third-value office conflict stays retained and
  needs further resolution. Claim release/takeover and an explicit keep-office
  outcome are not implemented. Do not delete the journal to bypass that fence.
- Matching native/backend versions must be deployed together. A missing owner
  API prevents this sync path; there is no pretend-success compatibility fallback.
- Separate-account physical CloudKit acceptance, production schema/signing,
  parallel navigation qualification, and live QBO/Google/payment acceptance are
  still required. This slice does not enable arbitrary model or accounting edits.
- Documents still need immutable upload-digest verification for same-size
  pre-read file replacement; the previous bounded reader does not prove that.

## Verification

File-backed SwiftData tests cover actual model saves, existing office references,
transaction authors, unsaved drafts, stale reviews, save/receipt failures, every
local sync-journal write boundary, confirmation cleanup and large Unicode values.
HTTP fixtures exercise original-source publication, encryption failure, current
roles/revocation, corrupt claims, pagination, exact identities and endpoint limits.

Evidence and retained failed runs are under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Owner Field Edits.pxQKzn`.
Only background commands and headless unit tests are used; no screen capture,
browser interaction, visible launch, signing, push, deployment or live-provider
mutation is part of this qualification.

Apple's [ModelContext contract](https://developer.apple.com/documentation/swiftdata/modelcontext)
and [history guidance](https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes)
inform the saved-context and author boundaries. Behavior is additionally verified
against the installed SDK with file-backed tests, not inferred from a UI mock.
