# Original QuickBooks file recovery

Checkpoint: 2026-09-08. Backend candidate `2026.09.08.38`, protocol 1.

This is a tested server prerequisite, **not a completed native receipt migration or a production deployment**. The current receipt retry queue and automatic invoice/estimate attachment callbacks still use the legacy direct-upload path. Do not describe those app paths as fixed by this checkpoint.

## Reproduced problem and implemented contract

`ReceiptsAndBillsView.syncDocuments()` queues a device file path and optional transaction type/ID after disconnection or any failure. The queue does not own an immutable company, realm, grant, original bytes or server operation. Retrying after reconnect can therefore use a different connection; a lost upload response can also lead to another upload. Its completion callback uses the currently selected job/stage instead of a retained original context. `QuickBooksInvoiceAttachmentSync` has a separate direct callback path and ignores model-save failures. Both require migration together.

The new service reserves and encrypts the original bytes **before** any QBO request. Identity consists of the current authenticated business, original QBO realm/environment/grant, stable client operation ID, immutable server upload ID, exact filename/MIME/SHA-256, typed transaction references and optional job-document context. The client receives an opaque revision, not OAuth credentials or a grant fingerprint.

| Endpoint | Operation |
| --- | --- |
| `GET /api/qbo-document-uploads?companyID=…&realmID=…&environment=…` | Metadata-only page of at most 50 records, current opaque connection revision, protocol and file limit. `after` selects the next page. |
| Same collection with `operationID=…` | Recover a lost reservation response using the original client operation. Cannot combine with `after`. |
| `POST /api/qbo-document-uploads` | Reserve the immutable file and intent. Does not call QBO. |
| `GET /api/qbo-document-uploads/{id}` | Read original status and provenance. Does not call QBO. |
| `GET /api/qbo-document-uploads/{id}/file` | Explicitly restore the verified original bytes as base64. |
| `POST /api/qbo-document-uploads/{id}/send` | Exact `{revision}` body. Claim once, then upload the retained original. |
| `POST /api/qbo-document-uploads/{id}/recover` | Exact empty object. Read QBO for the original marker; may settle the saved server record, never POST a replacement to QBO. |
| `POST /api/qbo-document-uploads/{id}/cancel` | Exact `{revision}` body. Cancel only a never-sent reservation; retain its bytes and tombstone. |

Reservation fields are exactly `companyID`, `realmID`, `environment`, `operationID`, `connectionRevision`, `file` and `targets`, optionally `jobDocument`. `file` is exactly `{filename, contentType, data}` with canonical base64. There is no arbitrary URL, filesystem path, provider token, actor, force/reset, email-send flag, or accounting payload.

Supported targets are Invoice, Estimate, Bill, Payment, SalesReceipt and Purchase: zero to four unique `{type,id}` pairs, normalized together. These are attachment destinations, not permission to create/update financial records. Files must have a safe UTF-8 filename of at most 255 bytes, an allowed extension/MIME pair and complete nonempty bytes up to 25 MiB. Strict JSON rejects duplicate keys, nonfinite values, excessive nesting, unknown fields and oversized requests.

## Original job and customer handoff

An optional `jobDocument` is an immutable envelope with these exact fields:

- `attachmentID`, `serviceCallID`, `localCustomerID`: original local UUIDs.
- `customerQuickBooksID`: the original provider customer reference.
- `kind`: a supported operational/support file kind; `expense_receipt`, fleet files and other internal-only types are not accepted in this envelope.
- `stage`: `before`, `after` or `supporting`.
- `documents`: one to four `{type,localID,id}` entries, Invoice/Estimate only, matching all upload targets exactly. Invoice support cannot select Estimate, or vice versa.

The service checks `customer_entity_mappings`, `billing_entity_mappings` and `billing_job_documents` in the original company/realm/environment. Device assertions cannot establish these shared links. The exact provider transaction must also retain the original CustomerRef. Validation runs before dispatch and across provider/authentication/confirmation boundaries; explicit recovery rechecks the provider customer as well. Missing or changed links leave the original file readable for review, without sending or confirming an unsafe handoff.

The envelope is encrypted with the file intent and returned on metadata/file recovery. It is **not** sent to Intuit as customer notes. A second operation cannot silently reassign an identical file/destination to another attachment, job, customer or stage, including by stripping the envelope. The server does not set CloudKit photo counts, documentation-complete state, invoice/estimate fields or job status. Native completion must validate this original context and persist an idempotent local application receipt before claiming those effects.

This optional envelope is not cryptographic proof of a CloudKit record or the contents of an internal file. Standalone uploads remain standalone: they provide no evidence authorizing operational closeout. Native authorization and source-file privacy checks remain required.

## Recovery and authority invariants

- Every entry point requires a current application session, active Admin role and exact original company. The service preserves the existing administrator-only QBO file authority; a client role or legacy API token cannot substitute for it. Another current administrator in the same business may review a retained upload without changing original authorship.
- Sending requires the original realm, environment and grant. A reconnect never rewrites saved ownership or makes an old uncertain upload sendable. Explicit recovery may use a fresh grant for the **same original** company/realm/environment, captured and revalidated around each provider read. Another reconnect during that read invalidates its evidence.
- Original-operation aliases and content/destination deduplication retain lost-response lookup identities. New client operation IDs do not bypass an existing non-cancelled original, even after reconnection. Conflicting original intent fails visibly.
- Encrypted metadata, file and state envelopes bind the original identifiers and revision. A plaintext state rewind or swapped ciphertext/lookup row does not authorize resend. Reservation and dispatch claims are transactional with audit persistence; encryption/audit failures roll back before dispatch.
- `reserved → sending → confirmed` is the successful path. An interrupted dispatch remains `sending` or becomes `uncertain`; neither permits another POST. A single verified recovery result can confirm it. Zero matches, duplicate matches, malformed responses or conflicting metadata do not reset it.
- Provider confirmation checks original marker, provider ID, filename, MIME, size, every exact typed reference, `IncludeOnSend:false`, and no inactive reference. This is metadata/marker evidence, **not a download and hash of provider-side bytes**. Live provider contract qualification is still required.
- Lists exclude encrypted file columns and raw bytes; explicit file reads revalidate SHA-256 and the envelope. Logs redact the recovery path/query. Fixed HTTPS Intuit hosts, exact routes/query templates, no redirects, bounded responses and sanitized errors prevent arbitrary fetching and provider-secret disclosure. There are no automatic HTTP retries, attachment edits/deletion or customer-send calls.

## Verification

Evidence directory: `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Upload Recovery.Xd96O9`.

- `BeforeRoute.log`: initial HTTP reservation regression returned 404.
- `BeforeJobContext.log`: new original-job cases failed against the context-free candidate; retained before implementation.
- `QualifiedFocused.log`: **46/46** focused service, adapter, HTTP and job-provenance tests pass.
- `QualifiedBackend39.log`: **610/610** complete backend tests on Python **3.9.6**, 62.794 seconds, process exit 0.
- `QualifiedBackend312.log`: **610/610** complete backend tests on Python **3.12.14**, 63.047 seconds, process exit 0.
- `QualifiedTools.log`: **52/52** tooling tests. Python compilation, both workflow files under actionlint and `git diff --check` also pass.
- `QualifiedSource.sha256`: four frozen backend source/test hashes, rechecked after both full-suite runs. No Swift, Xcode project or CloudKit schema source changed in this increment, so no new native build is claimed.

All six scoped paths match the original iCloud project byte-for-byte. Its empty Git index and 226 unrelated changed files were preserved.

The preceding published PR #18 head `c9af5d71e39691c13371067117476bf3e06e3479` has successful Backend run `34245007214` (Python 3.13/3.14) and a successful Mac job in Native run `34245007258`; its iPad job was still running during this checkpoint's verification. That hosted evidence predates this backend candidate. This checkpoint does not cancel/restart the live job or claim its results for these new files.

Tests use temporary databases, synthetic accounts and mocked QBO transport. They cover encryption, explicit file restore, current role/session/company checks, grant replacement, lost replies, duplicate submissions, concurrent dispatch, corrupt state/bytes/aliases, bounded pagination, cancellation without deletion, provider faults, refresh-time revocation, actual multipart parsing through the local HTTP handler, original job/customer link changes before/after dispatch and read-only reconnection recovery. They do not exercise a real business provider account.

Backup tests cover an exact reserved snapshot and a snapshot taken **after** the uncertain provider dispatch. They do not prove safety after restoring an older pre-dispatch snapshot over later committed provider state. Production restore must quarantine writes and reconcile such later activity; an enforced restore barrier and acceptance drill remain a release gate. Preserve the matching encryption key with authorized recoverable backups; losing it makes retained ciphertext unreadable. Do not clear records or rotate that key as a repair shortcut.

## Remaining work before native adoption/release

1. Implement a version-gated native client and encrypted, company-owned capture journal. Copy original bytes before releasing file-provider access; retain one client operation and the selected original job/transaction context. Persist every server identity/revision/status transition with visible save failures. Do not silently fall back to legacy direct upload when the server endpoint is unavailable.
2. Replace manual receipt uploads, batch/single retries and automatic invoice/estimate attachment callbacks with the same ownership mechanism. Resolve current shared backend/app-session identity, role and local CloudKit graph before mutation. Quarantine unowned legacy queue entries for manual original-file review, retaining recoverable files; never automatically adopt them into the currently connected business.
3. Use a compact recovery lane with readable file/status, “Check Original Upload,” “Save Original File,” and cancellation only for never-sent work. Do not expose raw code, paths, provider payloads or a misleading “Retry Now” for unknown outcomes. Keep iPad touch/keyboard and Mac navigation, loading/offline/denied states and accessibility under actual UI tests.
4. Apply confirmed results only to the original attachment/job/customer/document and stage. Use idempotent per-model receipts so repeated lookup, callbacks, relaunch or two-device reconciliation cannot increment documentation twice. A selected-job change must not redirect completion. A CloudKit record still loading is pending, not absent or complete. Define the later-estimate-to-invoice attachment transition without silently duplicating existing files.
5. Qualify provider sandbox behavior for every supported MIME and reference type, recovery query completeness, omitted/false IncludeOnSend behavior, metadata-only proof limits and the restore barrier. No live send is authorized by these synthetic tests. Qualify hosted Python 3.13/3.14 separately from local runtimes, then request any necessary deployment/provider approval.
6. Keep the full application goal open: top-ten HVAC competitor requirements, intuitive iPad-first/Mac journeys, Google integrations, role/tenant/offline behavior, user/technician item creation and QBO sync, signed two-device CloudKit merge, and real iPad-to-iPhone Handoff/Tap to Pay acceptance. This file-recovery increment does not replace those requirements.

## Current primary sources

Reviewed in Safari on 2026-09-08: [Intuit Attachable API reference](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/attachable) and [Attach images and notes workflow](https://developer.intuit.com/app/developer/qbo/docs/workflows/attach-images-and-notes). The reference defines Note filtering, FileName/ContentType/Size, exact EntityRef type/value, IncludeOnSend, hidden references, multipart upload, lookup and temporary download behavior. App limits are intentionally narrower than the provider's total multipart request limit; documentation is not live acceptance evidence.

No production deployment, real QBO request, accounting mutation, customer email, CloudKit schema promotion, signing/capability change, merge or physical-device installation is part of this checkpoint.
