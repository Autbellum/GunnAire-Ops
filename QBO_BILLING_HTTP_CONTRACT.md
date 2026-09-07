# Shared billing HTTP and assigned-job authority — 2026.09.07.26

## Current boundary

The staged publisher is now reachable through authenticated application HTTP
routes. It owns invoice/estimate dispatch and interrupted-result recovery on
those routes. A typed native client implements the same contract and retains
the initiating workspace through replies. **Existing Invoice/Estimate buttons
have not switched to this client.** They still use the previous native billing
workflow. This checkpoint does not claim an end-to-end native billing cutover,
complete field use, production deployment, or completion of the full suite.

The native handoff still needs structured sale-origin/service-address review,
shared legacy customer/item/document mapping, automatic office schedule-to-server
assignment synchronization with durable offline edits, and recovery/approval
navigation in the existing billing screens. Do not replace assigned technicians
with an office-only workflow or silently change a sold price to pass a check.

No live QBO, payment, email, signing, entitlement, CloudKit promotion or device
installation was used. The active full-app objective remains unchanged.

## HTTP contract

All routes require a current opaque GunnAire application session, not merely a
Google identity token or shared development bearer. They recheck active server
roles and the exact company/realm/environment. There is no direct-provider URL,
bearer, caller role, send/email, charge/refund, void or delete field.

| Route | Meaning |
| --- | --- |
| `POST /api/billing-publications` | Reserve immutable proposal and publish/recover the original Invoice or Estimate. |
| `GET /api/billing-publications` | Scope-bound publication history, 50 records/page with opaque `cursor` and `nextCursor`. |
| `POST /api/billing-publications/{id}/recover` | Provider reads only; never dispatch another accounting write. Body `{}`. |
| `POST /api/billing-publications/{id}/cancel` | Cancel only a never-sent reservation. Body `{}`. No document deletion. |
| `POST /api/billing-publications/approve` | Exact proposal plus `technicianEmail`; appropriate office role approves that draft. |
| `POST /api/billing-publications/draft-grants/{id}/revoke` | Revoke the original exact-draft approval. Body `{}`. |
| `GET /api/job-billing-assignments` | One original job's server assignment; office or current assigned technician only. |
| `POST /api/job-billing-assignments` | Dispatcher/admin compare-and-set assignment or revocation. |

Publication requests retain the original engine fields documented in
[QBO_SERVER_BILLING_ENGINE.md](QBO_SERVER_BILLING_ENGINE.md). Optional
`serviceCallID` and `assignmentRevision` must appear together. History queries
require `companyID`, `realmID`, `environment`, `documentType`, `localDocumentID`;
only `cursor` is optional. Each returned record also has the original
`localCustomerID` and `operation`. Field history filters each row by current
authority; opaque scope-bound pagination never exposes inaccessible attempt IDs.

Job reads require `companyID`, `realmID`, `environment`, `serviceCallID`. Writes
add `localCustomerID`, distinct normalized `technicianEmails`, explicit `enabled`,
`expectedRevision` and a stable `operationID`. Revision zero means no server
record exists. The server assigns revision one on creation. Each later mutation
requires the exact previously reviewed revision; revocation retains a tombstone.
The original job/customer binding cannot be replaced by a later roster edit.

A replay with the same operation and payload returns the same assignment only
while its revision is still current. If a later dispatch change already exists,
the old replay returns a conflict instead of restoring stale access. A new
request ID is not a license to bypass revision conflict resolution.

Maximum POST body is 1 MiB. Duplicate JSON keys and nonfinite JSON constants are
rejected before intent hashing. Errors use sanitized `error`/`code` JSON;
400 is malformed input, 401/403 is session/access, 409 requires review, and
502/503 means unavailable/unconfirmed provider or storage. No automatic POST
retry is part of either the HTTP engine or native client. An uncertain result
must be recovered through its original identity.

## Assigned technician permission

Only an active dispatcher/admin can establish the server roster. Members must
be active Field Technician business accounts. Standard and Accounting accounts
cannot alter job authority. No primary-email role bypass is used. Active office
approval, the original QBO authorization grant, customer/job identity and exact
assignment revision are checked again immediately before dispatch. An office
roster is not inferred from a device claiming `assignedToJob`.

An assigned technician may create an Invoice/Estimate or update the original
unpaid mapped invoice with ordinary approved pricebook lines. The fixed-origin
server adapter reads active QBO Item records; each sold unit price and US
taxable/nontaxable choice must match that evidence. No current price replaces
the saved sold price. Evidence older than 30 seconds, including time spent in
preflight, is not sufficient to dispatch as an assigned technician.

Discounts, price overrides, missing optional provider price/tax fields, or older
sold prices require an exact office-reviewed proposal grant. This retains the
exception price without silently repricing it. Such approval remains scoped to
the exact draft, technician, original company and grant, expires after seven
days, and requires a still-active appropriately authorized approver.

After an uncertain write, recovery verifies the original recorded sold values;
a subsequent pricebook change cannot rewrite that history or authorize a new
send. Local/provider document identity binds to its original job. Another job
for the same customer cannot gain update access merely by supplying the invoice
UUID or QBO ID. Existing unpaid/SyncToken/payment-exclusion guards remain.

This does not yet establish server-owned customer signatures, finalized job
state, change-order authorization, or containment of all legacy native bearer
credentials. Those remain real full-goal requirements, not UI-only permissions.

## Native integration contract

`BillingPublicationClient` exposes typed publish, list, recover, cancel,
approve/revoke and job assignment read/save operations through
`GunnAireBackendService.billingPublicationClient`. Callers must supply their
captured `QuickBooksDataAPI.CapturedWorkspaceWorkflow`. Replaced/cancelled
workspaces cannot accept late replies, and external-mutation uncertainty is
retained. The client checks returned company, customer, job, document, attempt,
provider, state and revision identities; rejects repeated history IDs/cursors;
and never falls back to a direct QBO create.

`BillingPublicationAddress` carries complete street/city/state/postal/country
fields. A free-form address is not guessed into a tax jurisdiction. Posting date
is an explicit Gregorian date. The server owns invoice/publication lineage;
proposal-option notes remain intact. Existing models and their CloudKit schema
are unchanged. No extra workspace/tab or account-email footer was added.

## Persistence and operations

Preserve the existing billing/payment tables and the new
`billing_job_assignments`, `billing_assignment_mutations`, and
`billing_job_documents` tables plus indexes. Rosters and original assignment
mutations are encrypted with the existing server payload key. Roster envelopes
bind their company/job/customer/revision and cannot be swapped between jobs.
Their integrity hash covers randomized ciphertext, not a low-entropy crew list
that could be enumerated offline. Public responses exclude the approving actor,
grant fingerprint, ciphertext and operation journal. Assignment and operation
identity writes share one transaction with audit recording. A failed audit
rolls everything back. Database backup/restore retains assignment, job/document
binding, original publication and no-resend recovery.

UUIDs are normalized before SQL mutations: differently cased native UUIDs must
not make cancellation/revocation silently succeed without changing the original
row, or allow a claim to return without consuming the durable dispatch permit.

Do not merge/deploy without the separate production review. Render follows
main. One authoritative transactional database and its matching encryption key
are required. Do not delete unknown attempts, reset revision tombstones or
restore older data to enable a write. Older code that ignores active billing
locks is not a safe financial rollback.

## Evidence and remaining work

Final current-source local acceptance: **100/100 focused billing tests,
316/316 Backend, 37/37 Tools, 1120/1120 Mac Catalyst logic tests, and
1122/1122 iPad tests (1120 logic plus Invoice launch and simple Mail UI)**.
Zero failures/skips in these completed runs. The twenty new native contract
tests are included in both platform logic totals. The hosted workflow's
fourteen selected UI journeys differ from these two focused local regressions.

Retained evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/QBO Billing HTTP/`.
`MacAcceptance.xcresult` and `iPadAcceptance.xcresult` retain the exact final
runs; their originals are
`/tmp/GunnAireQBORefreshMac/Logs/Test/Test-GunnAire Ops-2026.09.07_11-48-37--0400.xcresult`
and `/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.07_11-48-39--0400.xcresult`.
Final backend/focused logs use the `backend-final-v2` and `focused-final-v3`
names. Earlier 91/97/99 focused and 313/315 full results are retained but
superseded. Byte compilation and workflow lint pass. The Xcode manifest,
CloudKit stored model schema, signing and entitlements remain unchanged.
The optimized unsigned universal Mac Release also passes. `lipo -verify_arch`
confirms both arm64 and x86_64. Final executable SHA-256:
`a45a16aa14bcab2bdb1c2b97e15a34966b90c5eef1cc6b928cbfcf12c5a008d0`.
Its log is `gunnaire-billing-client-mac-release-final-20260907.log` in the same
evidence directory. The pre-existing external Metal-toolchain search-path
warning remains. Unsigned Shortcut/LinkDaemon/ScreenTime diagnostics are not
signed-platform acceptance. Mac UI host qualification is still separate.
No new UI design or signed-device acceptance is claimed by these client tests.

Native command scope: mirror project `/tmp/GunnAireQBOBuild.LvvxSD/GunnAire Ops.xcodeproj`,
scheme `GunnAire Ops`, `CODE_SIGNING_ALLOWED=NO`. Mac Debug destination is
`platform=macOS,variant=Mac Catalyst,arch=arm64`, selecting the full logic target.
iPad Debug uses M5 13-inch simulator `147D4CB6-85CC-4B17-BD35-8684E60E672D`,
iOS 26.2, serial full logic plus `testInvoiceWorkspaceOpensWithoutTerminating`
and `testMailWorkspaceUsesASimpleInboxInterface`. Release uses generic Mac
Catalyst with `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`. The mirror's source
and test directories point to the authoritative iCloud project.

The first backend-focused candidate had three fixture errors (a
duplicate helper keyword and a wrong grant-column name); corrected runs retain
the original failures. The first native build exposed a pre-existing enum-name
collision with the new DTO; the transport enum is now explicitly named
`BillingPublicationDocumentKind`. No existing billing UI enum was changed.

The preceding `99c24d5` checkpoint now passes all four hosted jobs:
[Native 34136412662](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34136412662)
and [Backend 34136412678](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34136412678).
These results do not qualify subsequent source changes.

Current primary source read in Safari on September 7, 2026:
[Intuit Item reference](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/item)
defines `UnitPrice` in home currency, `Taxable` for US companies and `Active`.
Optional absent values are not treated as zero/false authorization evidence.
The invoice, estimate, preferences and company references are retained in the
engine document. This pricing authorization policy is GunnAire implementation
behavior, not a claim that Intuit mandates office approval for discounts.

Next work remains native button/assignment/offline/recovery integration,
scalable legacy mapping and server incremental sync, signed/finalized locks,
explicit customer-send/payment-link options, payment-provider dispatch and
credential containment. The wider goal still includes signed cross-device
CloudKit/offline convergence, independent staff Apple accounts, Mac UI host
qualification, Google outbox/message-file links, vendor onboarding and approved
physical iPhone Tap to Pay with iPad Handoff. None is replaced by these tests.
