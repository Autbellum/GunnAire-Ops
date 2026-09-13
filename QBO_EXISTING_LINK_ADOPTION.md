# Reviewed existing QuickBooks links — 2026.09.07.28

## Implemented boundary

QuickBooks Management → Accounting Mappings → **Review existing QuickBooks
links** opens one native navigation page. An administrator can search existing
local Customer, Item, Invoice and Estimate links, read their exact QBO records,
compare the names, and explicitly confirm the shared mappings. Selecting a
document includes its existing linked customer automatically. Batches contain
1–25 records including those customers; the list initially displays 50 matching
records with an explicit Show more action.

This is an ID-preserving migration, not an accounting import or replacement
editor. It does not change local records, sold line prices, invoice amounts,
payments, QBO entities or customer messages. QBO calls are exact authenticated
GETs through the existing fixed-origin backend adapter. Item categories/bundles
are not accepted as billable item links. Inactive records can retain historical
links; that does not make them eligible for new billing. Paid invoice history
can be linked but remains protected by the existing unpaid-update checks.

Names and totals are visible for review. Internal identifiers are behind a
disclosure; provider payloads, private notes, tax IDs, credentials and account
emails are not an inbox-style data dump or a screenshot footer. Standard Back
navigation returns to the original QuickBooks Management page.

**Native Invoice/Estimate publishing still uses the retained native billing
workflow, not the shared BillingPublicationClient.** This feature supplies a
required shared-link prerequisite; it does not claim the billing-button
cutover, complete historical import, or full application acceptance is done.

## API, authority and consistency

All routes require a current opaque GunnAire application session and active
server Admin role. They enforce the configured company, realm and environment;
neither a client-supplied role nor the primary account email bypasses this gate.

| Route | Contract |
| --- | --- |
| `GET /api/qbo-link-reviews` | Exact companyID, realmID and environment; optional original operationID. Returns current opaque connectionRevision and that review or null. |
| `POST /api/qbo-link-reviews` | Exact scope, stable operationID, connectionRevision and 1–25 links. Reads QBO and retains an encrypted, immutable 15-minute review. |
| `GET /api/qbo-link-reviews/{id}` | Recover the original scoped review without another provider read. |
| `POST /api/qbo-link-reviews/{id}/confirm` | Body contains only the exact revision. Rereads all provider evidence, then atomically adopts all mappings and job bindings with the audit event. |
| `POST /api/qbo-link-reviews/{id}/cancel` | Same exact revision body. Cancels only the review; no entity or mapping deletion and no QBO request. |

Each link has kind, localID, providerID and localName. Documents also require
localCustomerID and may carry serviceCallID. Duplicate local/provider identities,
extra fields, duplicate JSON keys, nonfinite constants and bodies over 1 MiB
are rejected. Request IDs and local IDs are normalized UUIDs. Errors are
sanitized 400/401/403/404/409/502/503 responses with actionable native text.

Both preview and confirmation recheck authority after provider I/O. Confirmation
rechecks expiry inside the transaction and requires unchanged IDs, SyncTokens,
customer identity, names, relevant item price/tax fields and document evidence.
Only hashes of full financial lines/private notes are retained for change
detection, not those raw payloads. Encryption binds the review ID, tenant scope,
original operation, authorization grant and request hash. Its displayed revision
hashes randomized ciphertext rather than enumerable personal data.

One-to-one mappings cannot be replaced. An existing document's customer and job
binding cannot change. Reserved, sending or unknown publications must be
recovered first. Customer/item/document mapping, decision and audit writes use
one transaction; failed validation or audit rolls back the whole batch.
Repeated identical decisions recover the same result; opposite decisions fail.
Preview replay retains the original operation and never substitutes another
request. No automatic POST retry or direct-device QBO fallback is present.

## Interruption and reconnection

Before the preview POST, the native owner saves the original request in the
device Keychain, scoped by business/realm/environment/actor. It contains only
the original bounded links, not full QBO evidence. Storage failure blocks the
POST. Reopening retrieves the same operation from the server. Current actor,
role and captured workspace are rechecked around asynchronous replies; leaving
the page invalidates late results.

An uncertain confirmation hides both decision buttons until a GET recovers the
original status. The app cannot automatically resend a decision. Local edits
block confirmation but do not block cancellation of the original review.

Reconnecting the same business/realm invalidates confirmation of old evidence,
but the current administrator can still read and cancel that historical review.
This narrow recovery permission performs no QBO request or mapping adoption and
still rejects another realm, environment, company or revoked administrator.
If a current scoped lookup proves there is no review for an old-grant operation,
the app offers an explicit confirmation to replace only the unsubmitted local
request. An in-flight old-grant preview cannot subsequently commit because its
final grant check fails. Accepted decisions are never discarded as unsubmitted.

The journal is device-local recovery state, not a new CloudKit model. Shared
mapping authority is the backend. A second active administrator can recover a
known server review ID, but cross-device review-history discovery and a complete
initial/incremental QBO census are still required for broad migration tooling.

## Qualification and retained evidence

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/QBO Existing Links/`.

- Backend: 30 focused adoption tests; 349 complete Backend tests; 37 Tools
  tests; byte compilation passes. Tests use temporary databases, loopback HTTP
  and fixture provider transport, never production accounting credentials.
- Native: 15 new owner/client tests. The full Mac Catalyst logic target passes
  1174 tests (1185 parameterized device executions), zero failures/skips.
- iPad: 1181 tests pass (1174 logic plus seven selected UI journeys; 1192
  parameterized device executions), zero failures/skips. These include link
  cancellation, lost-confirmation GET recovery, reconnect/cancel, Invoice launch,
  existing-invoice line editing, simple Mail and retained tax-address entry.
  All three final existing-link screenshots were visually reviewed: readable
  names/status and standard Back, collapsed IDs, no raw payload or email footer.
- The optimized unsigned universal Mac Release passes, with arm64 and x86_64
  verified by `lipo -verify_arch`. Executable SHA-256:
  `31710bd11acb50a7504900d092dd4cb0fedeb345cb1b9e0ed53a674996a426b4`.
  Build uses generic Mac Catalyst, `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`.

Final bundles are `MacAcceptance.xcresult` and `iPadAcceptance.xcresult`.
The mirror project is `/tmp/GunnAireQBOBuild.LvvxSD/GunnAire Ops.xcodeproj`,
scheme `GunnAire Ops`, signing disabled (`CODE_SIGNING_ALLOWED=NO`). Debug Mac
uses `platform=macOS,variant=Mac Catalyst,arch=arm64`; iPad uses simulator
`147D4CB6-85CC-4B17-BD35-8684E60E672D`, M5 13-inch/iOS 26.2. Tests run serially,
selecting the full logic target and the seven journeys listed above on iPad.
The mirror source and test trees match the scoped review clone byte-for-byte.
The Xcode manifest hash remains
`52ecaabdb59c9d554d286f448a121eecd5a319afd6961bd9de62c3c075b315f7`.
No stored model, deployment target, signing or entitlement was changed.

The server suite includes atomic four-type mapping, wrong customer/lineage,
conflicting identities, pending publications, role/grant changes during reads,
expiry, tampered encrypted envelopes, concurrent confirmation, backup/restore,
HTTP validation and actual fixed-origin adapter → fixture GET round trips.
It also exercises an adopted unpaid invoice through the shared update engine
with the original customer/item/document IDs and sold amount; this is a fixture
engine test, not proof that the native billing buttons use that engine.

The first native build exposed a reserved Swift property name (`Type`) and an
actor-isolated default argument. They were corrected with an explicit CodingKey
and main-actor store resolution. A later reconnection test exposed a fake
backend returning a previous operation for an unscoped lookup; fixtures now
match the exact operation like the real server. Failed intermediate logs are
retained and are not counted as final passes. Existing unsigned LinkDaemon/
Shortcuts/ScreenTime diagnostics and older job-billing actor warnings are not
signed Mac UI acceptance or suppressed by this change.

## Operations and remaining full-goal requirements

Back up the complete transactional database, including qbo_link_reviews,
customer_entity_mappings, catalog_entity_mappings, billing_entity_mappings,
billing_job_documents, publication/payment journals and audit history. Preserve
the matching encryption key in approved secret storage. The restore test
verifies mappings and confirmed review recovery without another provider read.
The schema addition is forward-compatible. Do not drop these tables, erase
unknown attempts, restore stale financial data, or rotate the encryption key
to make a blocked action proceed. Stop link adoption on consistency or audit
failure and recover the original operation. Older code that ignores active
billing/payment locks is not a safe financial rollback.

There is no deployment, merge, Apple signing/entitlement change, physical install
or CloudKit production promotion in this checkpoint. Render follows main;
production promotion requires its own review and exact current acceptance.

Still required: immutable native billing proposal/approval/recovery handoffs and
actual shared publication cutover; all job creation/import authority; imported
document recovery and scalable sync; server finalization/signature controls;
server-owned payment dispatch and complete historical reconciliation; durable
Mail/Calendar coordination; vendor onboarding; approved PSP/Apple Tap to Pay and
physical iPad-to-iPhone acceptance; independent staff CloudKit sharing, signed
offline/multidevice convergence and distribution acceptance. The ten-competitor
matrix is an inventory, not proof that these end-to-end requirements are done.

Primary documentation reviewed in Safari on September 7, 2026:
[Intuit Item](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/item),
[Customer](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/customer),
[Invoice](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/invoice),
and [Apple toolbar/navigation guidance](https://developer.apple.com/design/human-interface-guidelines/toolbars).
