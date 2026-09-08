# Native original-file recovery

## Shared-device recovery checkpoint — 2026-09-08

The native Recovery workspace now offers **Files from Other Devices** for a
verified administrator in the current business and original QBO company. Its
Business Files sheet reads one 50-record metadata page at a time; originals are
downloaded only by an explicit Restore action. Failed paging retains the current
page, and an unavailable service is not presented as an empty successful result.

Restoring verifies the original file hash, scope, operation, destination and
monotonic server state before retaining encrypted bytes under the current local
owner. The original server envelope remains immutable; no first-device connection
revision or author is fabricated. Browsing, restoring and local application do not
reserve a replacement operation or upload another file. An explicitly sent,
previously reserved original uses its existing server operation. Uncertain,
confirmed and cancelled originals cannot be reset into a new send.

The restore sheet returns to the exact retained original, including after offline
relaunch. Finish Local Link retries only the original model receipt and durable
acknowledgement, without a network request. Missing CloudKit records remain
pending, not recreated or attached to a convenient replacement job. Changed local
bytes, customer/document identity, access or stale journal versions are rejected.
Job and customer Preview, job annotation and the Google Drive archive source can
use verified retained bytes when the original device path is absent. Preview uses
a protected owner/operation-specific temporary cache; it does not overwrite a
shared model's device path. An existing corrupt cache is rejected, not trusted.

Final local evidence is in
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Shared Files.Uf7D81`:

- `SharedPreviewMac.xcresult`: 1,468 logic cases passed without failures/skips.
- `SharedPreviewIPad.xcresult`: the same 1,468 logic cases and all seven selected
  UI journeys passed on the 13-inch M5 iPad simulator, iOS 26.2 (1,475 cases).
  These include shared restore/offline export and offline history, all three
  preceding local recovery journeys, invoice-tab stability and the simple Mail UI.
- Actual execution-tree verification confirms 1 Mac selector/1,468 cases and
  8 iPad selectors/1,475 cases. All 14 Swift hashes match
  `SharedPreviewSource.sha256` after both completed runs.
- Earlier `SharedIPad.xcresult` retained a selector failure: the filename appeared
  both in the sheet and in the list behind it after successful restoration. The
  sheet filename now has a unique accessibility identifier. Assertions remain;
  the corrected complete journey passes. Original failure artifacts are retained.
- All eight final screenshots were visually checked: Mail inbox, compose,
  message and trash confirmation; cancelled/recovered local originals; restored
  shared original and unavailable shared history. No account-email footer, raw
  response payload or device path appears in these screens.
- `SharedPreviewTools.log`: all 55 Tools tests pass. The workflow retains its
  previous 52 UI journeys and adds two, divided into two disjoint groups of 27.
  Complete logic targets, execution verification and Mac Release coverage remain.
- `SharedPreviewRelease.log`: unsigned universal Mac Release passes with Xcode
  26.6 (17F113); `lipo -verify_arch` confirms arm64 and x86_64. Both workflows pass
  actionlint and the final diff passes whitespace validation.

This is synthetic local acceptance, not a signed multi-device CloudKit or real
provider qualification. Backend protocol 1 / candidate `2026.09.08.38` is unchanged.
The preceding published PR #18 head `a02e838` has successful Backend checks on
Python 3.13/3.14 (run `34260770295`) and a successful Mac job in native run
`34260770325`; both iPad jobs were still running at this prepublication check.
Later source requires its own exact-head hosted checks. Publication and the
original-project copy are verified separately; no merge or deployment is implied.

Still open: standalone server records lack a portable local-attachment identity
for automatic CloudKit adoption; no local model is invented for them. Signed
same-record convergence, missing-model repair, later Invoice metadata linking,
richer job/Bill provenance, other file consumers, preview-cache lifecycle and
retention policy, older-backup restore protection, live provider acceptance and
the full HVAC/Google/QBO-item/Handoff/Tap-to-Pay goal remain release requirements.

## Earlier device-local checkpoint

2026-09-08 locally qualified checkpoint. This migrates native attachment entry points to the server
contract in [original-file recovery](QBO_DOCUMENT_UPLOAD_RECOVERY.md), backend
`2026.09.08.38`, protocol 1. It is not a production deployment or full-suite
completion. Final qualification and copy/publication status are recorded below.

## What changed

- Receipts & Bills captures the original file, typed destination and selected
  job/stage before starting asynchronous work. Its old device-path retry,
  backoff, clear and purge controls are removed. Existing legacy queue data is
  retained and flagged for review, never silently adopted into a new business.
- Automatic service-report attachments, generated invoice/estimate PDFs and
  billing-publication file follow-up use the same native coordinator. Application
  callers no longer use `QuickBooksDataAPI.uploadDocument`; its legacy adapter
  remains covered by transport tests but is not a fallback for these app paths.
- The native journal owns encrypted original bytes, filename/MIME/SHA-256,
  company, backend origin, actor, original QBO realm/environment, stable client
  operation, opaque connection revision, server identity and dispatch state.
  It captures a portable local attachment/customer/document identity even when
  an invoice has no job. Device paths and provider credentials are not persisted
  in this journal. Older extension-free display labels retain their file type.
- Mounted business authority, verified Admin role and matching active local user
  records are required. The legacy primary-email shortcut cannot authorize this
  journal. Authority is rechecked around every request and result; queued work
  cannot adopt a connection replaced before its Task starts.
- File-provider access and file reads are bounded. The service transport requires
  the current application bearer session, refuses legacy Google-ID-token fallback,
  permits only this contract's routes/methods and uses bounded, non-redirecting
  HTTP. There is no automatic direct-QBO retry if the backend is unavailable.

## Recovery and operational handoff

The compact File Recovery area lists readable filenames and statuses. Original
destination IDs are behind a disclosure. The detail sheet has one stable concrete
presentation owner, not a distributed Form Section. Actions are Check Original
Upload, Save Original File, and cancellation only before dispatch. Dispatched or
uncertain files cannot be sent or cancelled from this lane. A successful lookup
does not send another copy. Closing or cancelling an export retains the original.
Changing business/access dismisses private detail and clears prepared export data.

A local dispatch flag is persisted before the send request. Lost reservation
responses are looked up with the original operation, while lost send responses
are recovered from the original server record. Compare-and-set revisions reject
stale windows. Original ciphertext remains unchanged when metadata is advanced.
Cancellation retains an immutable tombstone and file; it is not deletion.

Manual job files require that job's original saved Invoice/Estimate and customer.
Before/after choices require an image type. The original operational file and
attachment are saved before upload; photo progress is derived at capture, never
incremented by a later callback. A changed selected job cannot receive an old
result. Confirmed provider IDs/reference receipts are applied only after the
original local file, customer, job and documents still match. Reapplying is
idempotent; failed model saves restore affected receipt fields. Automatic local
link-save failures restore historical provider evidence and stop before enqueue.

A confirmed provider upload remains in the attention list as “Saved in QuickBooks
— finish local link” until the exact original local receipt is saved and its
journal acknowledgement is durable. A failed local save or acknowledgement
therefore cannot silently hide unfinished work. Repeating that local application
does not upload a second file; an acknowledgement cannot be reset or reassigned.

The device store allows at most 512 retained records/512 MiB of original bytes
per owner, with a 25 MiB per-file limit. Metadata listing does not decrypt file
payloads. Storage/key/corruption errors retain existing files and stop safely;
they are not repaired by deleting the journal or regenerating its key.

## Evidence and qualification

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Native Uploads.V2lEeO`.

- `RecoveryMac.xcresult`: initial full Mac run, 1,444 tests with two failures.
  The old billing tests still mocked direct uploads and did not supply the new
  isolated company/client/journal boundary. Production checks were not relaxed.
- `BillingRecoveryMac.xcresult`: all 60 focused billing/client/journal tests pass
  through the actual new coordinator and encrypted store with synthetic transport.
- `NativeContextMac.xcresult`: all 1,454 logic tests pass, including original job
  capture, repeated photo capture, save rollback, changed bytes, access loss and
  lost-response recovery. These results precede the final UI/access refinements.
- `RecoveryIPad.xcresult`: all 1,454 logic tests pass. Three of five UI journeys
  pass; both new detail journeys fail to keep their sheet open. The original test
  recording/accessibility evidence is retained in `OriginalPresentationFailure`.
- `RecoveryPresentationIPad.xcresult`: after concrete sheet ownership, the full
  lost-response/relaunch/check/export-cancellation/reopen journey passes. The
  cancellation journey reaches its confirmation but the test query matches both
  underlying and popover buttons. The query now selects the actual confirmation
  sheet; no assertion or interaction is removed.
- The recovered-file screenshot was visually inspected: no account-email footer,
  raw payloads or paths. Low-contrast inherited gold status text prompted an
  explicit standard foreground in the recovery component/detail.
- `AcceptedMac.xcresult`: all 1,457 logic cases pass with no failures/skips.
- `AcceptedIPad.xcresult`: all 1,457 logic cases and seven selected UI journeys
  pass on the 13-inch M5 iPad simulator, iOS 26.2 (1,464 actual cases). These cover
  lost-reply recovery/relaunch/export cancellation, retained cancelled originals,
  verified access, operational workspaces, paired job transaction type/ID,
  opening Invoices without termination and the simple Mail interface.
- The actual execution verifier confirms 1 selector/1,457 cases for Mac and
  8 selectors/1,464 cases for iPad. All 18 Swift hashes still match
  `AcceptedNativeSource.sha256` after both runs. The accepted source includes
  the final durable local-application acknowledgement, unlike earlier green runs.
- `AcceptedMacRelease.log`: unsigned universal Release succeeds under Xcode
  26.6 (17F113); `lipo` verifies arm64 and x86_64. The verification command was
  corrected to put the input file before `-verify_arch`; a source manifest check
  was rerun successfully from the repository rather than the evidence directory.
- All seven screenshots in `AcceptedIPadImages` were visually inspected: Mail
  inbox/compose/message/trash confirmation, cancelled and recovered originals,
  and the paired Estimate target. No account-email footer or raw response payload
  appears; the existing advanced receipt form still exposes its transaction ID.
- `FinalBackend.log`: all 610 backend tests pass on Python 3.9.6; backend source
  is unchanged from the preceding separately qualified protocol checkpoint.
- `AcceptedTools.log`: all 55 Tools tests pass. Both workflow files pass
  actionlint, and `git diff --check` passes. Three new tests execute the real
  workflow selection script; they caught invalid shard IDs exiting successfully.
  An explicit exit now rejects those IDs. No test or assertion was removed.

Synthetic fixtures use isolated files, stores and responses; the UI provider
fixture is compiled out of Release and requires the explicit test-database flag
and a unique fixture UUID. No real customer file or provider was used as a fixture.
Simulator/export cancellation tests do not prove a signed physical-device export
or multi-device CloudKit merge.

## Remaining requirements and release gates

1. Publish/review the backend-first protocol change and qualify real sandbox file
   types, typed references, recovery queries and authentication boundaries before
   production use. This client deliberately has no unsafe compatibility fallback.
2. Qualify the shared-server history/download/adoption added in the checkpoint
   above on signed devices. Standalone server records still lack portable local
   attachment identity; signed CloudKit convergence and controlled multi-device
   tests remain necessary.
3. Define a reviewed metadata-link operation for adding a later Invoice to an
   existing Estimate attachment; current code retains/reviews the existing file
   instead of uploading a duplicate. Manual job-associated Bill uploads also need
   a richer shared provenance contract; standalone Bill uploads remain supported.
4. Provide a reviewed operational reattachment path when a manual capture's model
   save fails. The encrypted original and intended job identity remain available
   for export/review, but the UI cannot recreate that missing model automatically.
   Define archival/retention management before retained files reach device quota.
5. Enforce and drill the backend's older-snapshot restore barrier. An old reserved
   backup restored over later provider activity must not permit a duplicate send.
6. Complete the full ten-competitor HVAC requirements, remaining Google/provider
   integration migration, technician-created items and QBO acceptance, intuitive
   iPad/Mac handoffs, signed CloudKit and physical iPad-to-iPhone Handoff/Tap to Pay.
   This file-recovery change is one necessary increment, not replacement scope.

At prepublication verification, PR #18's published head is `c9af5d7`.
Backend run `34245007214` and Mac in
native run `34245007258` passed. The iPad job is terminal/cancelled with GitHub's
explicit 60-minute timeout annotation, not a live wait or complete green result.
The prepared workflow retains all previous 48 UI selectors and adds four, then
distributes all 52 across two disjoint 26-journey iPad groups. Each also executes
the complete logic target; Mac coverage, time limits, execution verification and
read-only permissions remain intact. Earlier hosted results do not qualify this
checkpoint; its exact published head still requires new hosted results.

The scoped original-project synchronization covers 23 paths and is separately
verified before commit, including 220 unrelated changed files and the empty
original index. Publication is to existing PR #18, not a duplicate or a merge.

Primary guidance reviewed in Safari: [Intuit Attachable reference](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/attachable)
for exact file metadata, references, IncludeOnSend and read/update behavior;
[Apple disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)
for keeping essential recovery actions visible and advanced destinations hidden.

No real QBO write, financial mutation, customer email, production deployment,
CloudKit promotion, signing/capability change, merge or physical install occurred.
