# Server-owned QuickBooks change history

September 7, 2026; backend candidate `2026.09.07.33`. This is an implementation
checkpoint, not a deployed service or completed application acceptance.

## What this implements

`Backend/qbo_change_capture.py` provides authenticated, company-scoped initial
collection reads and incremental change capture for the thirteen accounting
collections currently refreshed by native QuickBooks Management: Account, Bill,
Customer, Deposit, Estimate, Invoice, Item, Payment, PaymentMethod, Purchase,
SalesReceipt, Vendor and VendorCredit. Provider requests are GET-only, use the
original server-held grant and fixed Intuit accounting origins, and cannot
charge, publish, email, void, delete or act as a general proxy.

Every distinct observed record version is encrypted in a company/realm/
environment/entity-bound envelope. Earlier versions, sold prices, allocations
and deletion tombstones are retained, not replaced by the latest arrival.
This is an observation journal: it cannot reconstruct every intermediate
provider change between reads, nor does an arrival sequence establish provider
version order. Consumers must reconcile timestamps, identity and financial
semantics before applying any record.

## Verified provider contract

The current primary pages were read in Safari on September 7, 2026:

- Intuit recommends CDC catch-up from the last processed event per entity,
  allows out-of-order notifications, and requires prompt webhook delivery
  acknowledgements with complex processing outside the receiver.
  [Webhook best practices](https://developer.intuit.com/app/developer/qbo/docs/develop/webhooks/best-practices)
- CDC returns full changed objects and deletion records, with a 30-day
  look-back and a maximum of 1,000 records per request. Its documented request
  supplies entities and changedSince, not a pagination or end-time parameter.
  [CDC reference](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/changedatacapture)
- Queries support counts and offset pagination. Active/inactive list records
  require an explicit Active filter. Query pages are not documented as an
  atomic snapshot.
  [Query operations](https://developer.intuit.com/app/developer/qbo/docs/learn/explore-the-quickbooks-online-api/data-queries)
- Customer merge notifications include `data.deletedid`; employee events can
  carry namespace-qualified alternative identifiers. Not every event carries
  a data object.
  [Webhook data objects](https://developer.intuit.com/app/developer/qbo/docs/develop/webhooks/data-objects)

The two-minute overlap, conservative initial-enumeration acceptance, size
bounds and authorization rules are GunnAire implementation decisions, not
additional Intuit guarantees. The existing minor-version 75 pin is retained.

## Capture and recovery rules

1. A current active Admin application session and exact company/realm/
   environment are required. The primary-email shortcut and shared API token
   cannot authorize this endpoint. Session, role and grant are rechecked around
   provider requests, inside the commit, and before returning decrypted history.
   Ordinary refresh-token rotation preserves grant identity; reconnecting does
   not let an in-flight request adopt the replacement grant.
2. Initial enumeration counts and reads every page, including inactive list
   objects, validates IDs and full dated records, rejects repeated/partial pages,
   and checks the count again. CDC then overlaps the enumeration. If changes
   could have shifted records across offset pages, history is still preserved,
   but `baselineAt` remains unset and the next capture repeats the enumeration.
   Matching counts alone are not presented as a completed initial snapshot.
3. Each collection has its own capture cursor and optimistic revision. Versions,
   cursor, batch metadata and audit entry commit in one transaction. A newer
   completed capture prevents an older suspended request from overwriting it.
4. Newly received webhook rows rewind the look-back when their event time is
   older. Notifications arriving during a capture remain for the next capture.
   The receipt position advances only through original events with sufficiently
   dated stored records. Deleted events require actual tombstones; merges need
   both identities. Missing records continue to rewind on subsequent attempts.
5. Exactly 1,000 CDC records is treated as potentially truncated. Old gaps,
   malformed pages, throttling and provider failures retain the saved cursor.
   The code never moves the look-back forward to hide an incomplete response.
6. Replay deduplicates identical versions. Status/history requests read only
   saved encrypted evidence and do not contact Intuit. History pages retain a
   fixed upper sequence while newer captures continue. Responses are bounded,
   and encrypted payloads are checked against their stored scope, identity,
   timestamp, status and digest before release.

## Server contract

`POST /api/qbo/change-capture` accepts exactly `companyID`, `realmID`,
`environment` and `entityType`, all identifying the original workspace and one
supported accounting collection. It performs one synchronous capture request.
It is not a webhook callback or an automatically scheduled background job.

`GET /api/qbo/change-capture` accepts the same fields as query parameters, with
optional nonnegative `afterSequence` and `throughSequence`. The first response
supplies `throughSequence`; subsequent pages keep it unchanged and use
`nextAfterSequence` until null. These are observation-history pages, not a latest
record projection or a financial ledger already reconciled with the app.

Responses include scoped collection identity, revision, `capturedThrough`,
`baselineAt`, `issueCode`, `legacyEventsNeedingReview`, versions and page cursors.
`applicationState` is explicitly `not_applied`. Important review states include
`baseline_changed`, `event_record_missing`, `history_gap` and `change_limit`.
The native interface still needs natural-language recovery actions for these.

The receiver now retains only validated merge/alternative identifiers from the
data object. New notifications are bound to the saved company, environment and
grant in the same insertion transaction. Existing legacy rows are preserved
with unknown scope rather than assigned a guessed company/environment. Their
review count is reported; no historical record is silently adopted or removed.

## Verification

Retained local evidence:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/QBO Change Capture.r3lvH4/`.
Python 3.9.6 is the available local runtime; hosted 3.13/3.14 results are separate.

- Expanded focused qualification passes 44 tests: 38 capture/provider/service
  tests and six webhook tests (`FinalFocused2.log`).
- Final frozen-source qualification passes all **488 Backend tests**
  (`FrozenBackend.log`, 57.517 seconds) and all **37 Tools tests** (`Tools.log`).
  Earlier complete runs (483, then 488) also pass; they do not replace the final
  frozen-source run. The new module's SHA-256 is
  `6174b28d67e22032263fe691b1425cefe2cc5cf5eb5bf5f26315113b8372181f`.
- Coverage includes actual injected provider HTTP requests, initial/incremental
  persistence, saturation, late/missing/merged/deleted events, role/session/grant
  changes, concurrent runs, encryption/commit failure, pinned history paging,
  tampered records, additive migration and verified backup/restore without a
  provider call. All business/accounting inputs are fixtures.
- `FinalFocused.log` retains one failed fixture setup: the backup test omitted
  its empty document-storage directory. The fixture now creates that directory
  and performs the real backup verification and restore drill; no product
  backup assertion or safety check was weakened.
- Backend/Tools compilation and whitespace checks pass. No native source,
  project, signing, entitlement or CloudKit schema changed. The unchanged PBX
  SHA-256 is `52ecaabdb59c9d554d286f448a121eecd5a319afd6961bd9de62c3c075b315f7`.

The prior PR head `6a0a38e` is separately verified: hosted Backend and Mac pass;
iPad passes all 1,271 logic tests but fails two interface assertions (existing-
link switch selection and initial tax-address entry). `NATIVE_CI.md` records
the exact completed job and log digest. Those failures predate this backend
change and remain unresolved; no hosted iPad acceptance is claimed.

## Still required for the complete application

This new server path does **not** replace the existing native refresh/import or
legacy webhook acknowledgement endpoint yet. The generic all-ID acknowledgement
gap described in `QBO_SYNC_WORKFLOW_LIFECYCLE.md` remains open. Capture timestamps
and receipt positions must never be substituted for per-event application proof.

Next work must connect native captured workspace runs to this history, retain
version metadata through local commits, implement dated deletion/void/merge/
payment-reallocation outcomes without erasing financial history, and acknowledge
only events with confirmed application receipts. It must also add shared
conflict-resolution UI, server-driven background scheduling/recovery, staged
high-volume/expired-window recovery, legacy-scope review, other required QBO
entities and independent device-consumption cursors.

The endpoint's initial memory/time bounds (100,000 records, 64 MiB census,
16 MiB provider response) are explicit safety limits, not proof that larger
companies are supported. Incomplete/oversized collections require a staged
transfer path. Same-time conflicting record versions require review; this
journal does not choose a financial winner by arrival order. Operations are
append-only through this service, but a complete tamper-evident audit chain and
retention/repair policy are separate full-suite requirements.

Complete Google/CloudKit multi-device/offline workflows, iPad/Mac usability,
iPhone Handoff/Tap to Pay, staff/vendor onboarding, ten-suite feature acceptance,
production-provider qualification and distribution signing remain open. No live
accounting operation, deployment, merge, message, schema promotion or physical
installation was performed here.
