# Native billing publication — candidate 2026.09.07.29

Follow-on native entry-point changes are documented in
[BILLING_ENTRY_POINT_UNIFICATION.md](BILLING_ENTRY_POINT_UNIFICATION.md).
The historical secondary-path limitation below describes this checkpoint;
the follow-on candidate replaces management raw creation and payment preparation
creation with the saved-document lifecycle and explicit collection boundary.

The Billing Documents invoice/estimate actions and QuickBooks Management's
local-document retry actions now use the shared billing service. Production
instances of `QuickBooksBillingWorkflow` cannot fall back to a direct accounting
write. The old provider implementation is retained only for isolated legacy
transport tests. This is an implementation checkpoint, not full-suite completion
or permission to deploy, merge, sign, promote CloudKit, or touch live accounting.

## User workflow

- Keep the existing invoice/estimate builder, technician-created items, sold
  quantities/prices, pricebook review, structured service/sale addresses and
  customer publication handoffs. An unmapped historical link needs the existing
  administrator Existing Links review; the app does not guess a replacement.
- Confirm shared customer/document mappings and current business/job authority
  before preparing the accounting request. Office drafts keep their original job
  without inventing a technician-assignment revision. Assigned technicians use
  the real server revision and current pricebook evidence. Price exceptions can
  receive explicit, exact-proposal office approval without repricing.
- Persist the immutable proposal in an atomic authenticated encrypted file
  **before** POST. The device-only Keychain key is not exported to CloudKit or
  backup. Scope includes company, realm, environment, account and document.
  Missing/corrupt storage fails closed; it is not replaced by an empty queue.
- A lost reply triggers original-attempt lookup and read-only provider recovery,
  never an automatic publication of a newly rebuilt draft. A separate explicit
  review action may submit the original reserved proposal. Sending/unknown
  attempts cannot be resubmitted or cancelled. Only never-sent reservations can
  be cancelled; no QuickBooks entity is deleted.
- Billing Review is pushed from the existing invoice, estimate, job billing or
  management retry row. It displays the customer, original prices, dates and
  relevant actions. Notes are collapsed and line lists page in groups of 20;
  no raw JSON, provider credentials or account-email footer is displayed.
  Native Back returns to the original document. Invoice disclosure identifiers
  are scoped to their heading so child actions retain independent identities.
- The server retains an opaque native `draftRevision` alongside the encrypted
  proposal. A second device with the identical saved draft can recover that
  original operation without the first device's key. A changed unlinked draft
  cannot be marked synced from an older confirmation. This is a tested recovery
  protocol, **not evidence of physical-device CloudKit convergence**.
- Existing mapped estimates use an exact read, without forging app lineage or
  creating another estimate. Invoice updates retain the accounting posting date
  and SyncToken and require an unpaid accounting balance. Payment, completion,
  signatures and local draft changes continue to prevent inappropriate writes.
- Confirmations update only the original local document and job activity.
  Failed local saves retain the server identity for recovery and restore only
  this operation's sync fields. Supporting-file follow-up retains its existing
  exact-file/lifecycle guards; file failures do not undo a confirmed invoice.

## HTTP additions and compatibility

All routes require the existing opaque application session and recheck current
active roles and exact company/realm/environment. They expose no provider token.

| Route/field | Contract |
| --- | --- |
| `GET /api/billing-publications/context` | Exact document/customer scope and optional original job. Returns shared mapping, opaque connection revision and current office/assignment authority; a mapped document is read by exact provider ID. Field users cannot read an existing unbound invoice simply by supplying another job for the same customer. |
| `GET /api/billing-publications/{id}` | Immutable original proposal and original state; no provider write. Appropriate current office users can inspect an old-connection attempt, with `connectionChanged: true`, but cannot publish or approve it. |
| `POST /api/billing-publications/{id}/approve` | Body contains only the displayed `proposal`. The server chooses the original technician, requires an exact hash and reserved state, and rechecks inside the approval transaction. No publication/payment/email is performed. |
| `connectionRevision` | Mandatory 64-character lowercase hex on new publication requests. A retained request cannot adopt a replacement QuickBooks grant. |
| `draftRevision` | Optional bounded opaque hash for compatibility; the new native workflow supplies it for identical-draft cross-device recovery. It grants no authority. |
| `serviceCallID` | May appear without `assignmentRevision` for office publication. A field claim still needs the real matching assignment revision or an explicit office draft grant. |
| Existing cancellation | An appropriate current office user can cancel an old-connection **reserved** attempt in the same company/realm/environment. Consumed attempts, other businesses and accounting entities remain protected. |

Deploy backend candidate 2026.09.07.29 **before distributing the new native
client**, after separate deployment approval and backup/restore review. The
currently deployed backend may not have these routes/required-field support.
Do not use a direct-write fallback to bridge that rollout gap. Older native
releases still have separate legacy paths and need a managed release cutover.

No SwiftData model, CloudKit schema, entitlement or signing change is required
for this checkpoint. The original iCloud worktree's unrelated edits are retained.

## Evidence and remaining work

Local evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Native Billing Cutover/`

Final local candidate acceptance passes **1191 Mac logic tests** and **1195 iPad
tests** (1191 logic plus the two Billing Review journeys, Invoice launch and
simple Mail). Both result bundles report zero failures, expected failures and
skips; parameterized device executions are 1202 and 1206 respectively. Backend
passes **366** and Tools **37**. The unsigned optimized Mac Catalyst Release
build succeeds, and `lipo -verify_arch arm64 x86_64` confirms both architectures.
Release executable SHA-256:
`438c98114f6c90255ae80f09e088fa0681eca747746f8bffdb351d3aa4a1f460`.

Six final iPad screenshots were visually inspected: cancelled unsent billing,
read-only accepted-invoice recovery, Inbox, Compose, message reading and Trash
confirmation. The account-email footer is absent, native Back/Cancel is retained,
and no raw accounting or mail payload appears. Both new review journeys pass
after correcting inherited accessibility identifiers and seeding explicit
fixture-only catalog mappings. Initial failure logs are retained. The workflow
candidate adds these two journeys for 22 iPad selections. New hosted checks must
qualify the exact published candidate; preceding head `9821668` passes all four
jobs, but those results are not evidence for this new source. This is fixture and
simulator qualification, not live accounting, physical-device or signed release
acceptance.

This does not migrate the separate raw QuickBooks Management create forms or
the payment-service legacy invoice-creation path. Credential containment, complete
initial/incremental import, independent staff CloudKit sharing, physical
multi-device/offline acceptance, all job-creation/import authority paths, server
completion/signature ownership, payment reconciliation and iPad-to-iPhone Tap to
Pay/provider entitlements remain part of the unchanged full-app goal. Vendor
commercial/API access, remaining Mail/Calendar coordination and production
integration/distribution acceptance are also not claimed complete.

## Primary guidance checked in Safari

- [Intuit Invoice reference](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/invoice): exact reads, update SyncToken, posting date, line limit, sales-tax locations, calculated totals/balance and imported-invoice auto-email conditions. Server-owned explicit no-send/payment flags remain intact.
- [Apple Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars): deliberate action density, concise titles and standard Back/Close behavior.
