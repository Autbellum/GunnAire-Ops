# Shared field-payment review

Candidate backend `2026.09.08.39`, 2026-09-08. This is a read-only payment-handoff
increment within the full HVAC business-suite goal, not a finished payment
processor, reconciliation rollout, or production release.

## Correct invoice identity and narrow reads

The preceding contactless guide copied `Invoice.quickBooksID` as a searchable
invoice reference. Intuit distinguishes its internal `Id` from the customer-facing
`DocNumber`. The guide now obtains the actual number from the shared business
server. A missing number remains missing; the user can match customer, date and
total in QuickBooks. No local UUID or internal QBO ID is presented as that number.

The preceding payment-check action separately fetched an invoice and the entire
Payment collection, then called a broad SwiftData import. This flow replaces it
with exact linked-record reads and an ephemeral, invoice-scoped observation.
It deliberately does not apply a broad import, mutate saved invoices/receipts,
complete assignments, infer bank settlement, or send another charge.

## Contract and authority

`GET /api/field-payment-review/context` accepts exactly `companyID`, `invoiceID`,
`localCustomerID`, `invoiceQuickBooksID`, `customerQuickBooksID`, and optional
`serviceCallID`. An approved app session, current business, original customer and
invoice mappings, and original job binding are required. The response adds the
server's realm, environment and opaque connection revision. Field devices do
not need a local QBO OAuth bearer to discover the approved shared connection.

`GET /api/field-payment-review` requires the same identity plus that exact realm,
environment and revision. Only Admin, Accounting, or the currently assigned
Field Technician may read it. Revoked/deactivated staff, stale or reassigned
collection tasks, changed mappings, another business, and a replaced QBO grant
cannot produce a successful observation. Completed assignments may be reviewed
but provide no new collection allowance. Office financial review remains
distinct from dispatcher-only scheduling access.

The server checks authority before and after each provider read, including
before refresh, after refresh, immediately before the GET and after its result.
SQLite read snapshots end before network I/O. Invoice `LinkedTxn` Payment IDs
drive exact Payment reads; unrelated invoice/estimate records are not fetched.
Payments and the invoice are re-read, with original version, date, amount,
allocation and identity comparison. Mixed observations fail, not partially
succeed. Reads are bounded to 32 linked payments, 750 payment lines, 1 MiB per
provider response, and a 60-second review deadline. Larger histories require
Accounting review in QuickBooks; there is no silent truncated success.

The minimal response includes protocol version 1, scoped identities, original
invoice number/date/version, USD total and balance in cents, observed time,
invoice-only payment allocations, access kind, open-attempt hold and observed
collection limit. Credit/adjustment applications are identified as accounting
applications, not new cash. `fundsSettlementVerified` is always false.
Raw payloads, card data, customer contact information, credentials, internal
grant fingerprints and unrelated document IDs are excluded. Responses are
`no-store`; request query identities are redacted from access logs. Audit and
credential refresh may write server security metadata, never accounting data.

## Native handoff

The Contactless Payment sheet shows customer, saved balance and verified QBO
invoice number/balance. Collection steps and applied-payment history are
disclosures. All financial roles, including assigned field staff, use the same
shared check. Retry/offline/service-update messages are app-authored, not raw
backend errors. No unchecked result is cached in UserDefaults or CloudKit.

The native client pins company/session/generation/role and the exact original
SwiftData invoice/customer/document fields across both requests. It rejects
changed access, replacement objects, stale observations, mismatched identities,
invalid money, duplicate allocations, unknown versions, and oversized responses.
Transport is ephemeral, bounded and does not follow redirects or fall back to
Google ID tokens or device QBO credentials. Handoff remains an expiring local
invoice UUID only. No customer or card data is placed in the activity.

Opening QuickBooks checks that the displayed observation is less than one minute
old and still belongs to the original workspace. Returning to the app refreshes
the check. Paid invoices and unresolved in-app attempts do not offer another
collection. Other verified entry starts with Cash selected and a value capped to
the observed allowance. These are UI safeguards, not a financial send permit:
the accounting provider and another payment app cannot be transaction-locked by
this GET. The existing payment journal still owns in-app card/ACH reservations.

## Rollout, recovery and remaining requirements

Do not deploy automatically or merge to `main` as part of this checkpoint.
Publish the reviewed backend before distributing this native screen; older
servers return an explicit service-update error without falling back to a broad
or unscoped read. There is no database or CloudKit schema migration in this
increment. Rollback must preserve all existing payment journals, mappings,
assignments, files and app data; never clear a journal to regain collection access.

Open requirements remain: narrowly applied and idempotent accounting receipts,
complete financial lifecycle/ACH returns and settlement, cross-channel duplicate
protection, extensive-history paging, real provider acceptance, actual iPhone
Tap to Pay capture through an approved processor and Apple entitlement, signed
iPad-to-iPhone Handoff, same-record CloudKit convergence and offline conflict
acceptance, supplier approvals, production Google/QBO permissions, and the full
top-ten-comparator suite qualification. This screen does not claim that embedded
Tap to Pay has been enabled or that opening QuickBooks confirms a collection.

## Evidence

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Payment Review.N3jbg7`.
The first focused HTTP test failed with the expected missing-route 404 before
implementation. `BackendFinal.log` passes 636 tests, including 26 new review,
session, privacy and provider-boundary cases; `ToolsFull.log` passes 55.
`ReviewMacInitial.xcresult` proves execution of all 10 new native logic cases.
Final `ReviewMacFinal.xcresult` and `ReviewIPadFinal.xcresult` each pass all 1,478
logic cases; iPad also passes all nine selected UI journeys (1,487 total cases).
The actual execution verifier checks one full Mac target and all ten iPad
selectors, with no failures, skips or absent cases. The initial offscreen-button
UI assertion failure is retained; the corrected journey scrolls back, taps
verification and verifies the refreshed invoice instead of weakening assertions.
All ten final screenshots were visually reviewed: six payment states and four
Mail states, with no raw API payload or account-email footer. `ReviewRelease.log`
passes unsigned universal Mac Release and both architectures pass `lipo`.
Both workflows pass actionlint and the real 58-selector script passes its shard
tests. These results do not establish deployment, signed devices or hosted
acceptance of this new source.

Current primary sources, inspected in Safari on 2026-09-08:

- [Intuit Invoice API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/invoice): `Id`, `DocNumber`, invoice reads and targeted linked Payment reads.
- [Intuit Payment API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/payment): allocations across invoices/credit memos, unapplied funds, versioning and exact Payment reads.
- [Apple disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls): keep common actions visible and label optional details clearly.
