# QBO billing publication lifecycle

## Scope and current status

Implementation checkpoint, September 7, 2026. Final native tests and the
unsigned universal Mac Release build pass; arm64 and x86_64 are verified.
This is not full application, signed-device, CloudKit Production, or live-provider
acceptance. The full business-suite objective remains open.

The active Billing Documents invoice/estimate publisher and QuickBooks Management
local-document retry queue now share QuickBooksBillingWorkflow. Capture occurs
before scheduling work; customer lookup/create, approved catalog publication,
document lookup/create/update, local confirmation and optional linked-file upload
retain the original company/provider operation, actor access and ModelContext.
The existing invoice editor, pricebook review, and pending/retry navigation remain.

## Correctness boundaries

- Fresh local users must agree with the verified workspace role. Administrators
  may publish; accounting may publish invoices; dispatchers may publish estimates;
  technicians require current lead/crew assignment for the document's customer/job.
  Management retry and global catalog promotion retain administrator requirements.
  There is no primary-email administrator bypass in this policy.
- Capture exact document fields, customer contact/mapping, catalog model instances
  and approved revisions, and relevant payment identity/amount/provider state.
  Replacement records, duplicate UUIDs, edits, role loss, cancellation and account
  replacement stop later requests and local mutations. A one-shot owner prevents
  overlap on the same screen; leaving that screen cancels its owners.
- Check immutable sold quantities/prices, finite nonnegative amounts, authorized
  discounts and subtotal agreement before customer/item writes. Current pricebook
  updates never reprice an existing invoice or estimate.
- Reconcile a complete customer/catalog/document query before create. Retain
  stable customer/item/invoice/estimate request IDs; require one-to-one mappings.
  Catalog replay preserves the approved proposal and stages differences.
- Invoice updates require fresh exact document/customer identity, SyncToken and an
  authoritative full unpaid balance. Missing/partial/paid balances prevent POST.
  Returned significant lines must match the sold items, quantities, prices, tax
  codes and discount; a QBO subtotal row is allowed. Missing line evidence is not
  a successful sync. Zero-priced lines still require an explicit reported amount.
- Validate response identity and lineage before linking new documents. A recovered
  old version with different lines remains a review case, not an overwrite or a
  second create. Missing final balance can link the verified document but requires
  balance refresh before collection. Tax review remains separate.
- Preserve estimate change-order reason in the common publication note. Store job
  publication activity with the confirmation. On save failure restore only the
  workflow's sync fields and remove its unsaved activity, never roll back unrelated
  records. A failed/late save cannot announce successful sync.
- Supporting-file follow-up retains original document references, attachment model,
  content bytes and permission checks. Record attached entity keys on success.
  File failure leaves the confirmed invoice intact and reports files pending.
  No payment or customer-email send is part of this workflow.
- Fix the invoice mutation policy's unresolved CloudKit Payment.invoice access and
  reject the Int64 currency boundary before conversion; neither may crash billing.

## Provider contract evidence

Read in Safari on September 7, 2026:
[Intuit basic ID and field definitions](https://developer.intuit.com/app/developer/qbo/docs/learn/learn-basic-field-definitions).
Intuit documents realm-scoped request IDs, the requestid query parameter, replay
of the original response for the same request/content, and a 50-character limit
outside batch. The new estimate key is 48 characters. A DocNumber is not treated
as an idempotency key. Public text retrieval returned a JavaScript placeholder;
the loaded Safari document supplied the actual contract. No account sign-in or
live API mutation was necessary.

Stable keys plus read-before-create do not establish indefinite exactly-once
behavior, an immutable server-owned payload, or cross-device dispatch authority.

## Verification

The initial focused Mac suite passed 26/26. The first expanded iPad/Mac build
failed because Management passed its compatibility wrapper instead of the underlying
QuickBooksDataAPI. Corrected that call; an intermediate expanded run passed 936/936
logic tests on both platforms and 6/6 iPad journeys. Three additional stored-money
and model-deletion tests were then added; the final source passes:

- Mac Catalyst arm64 Debug: 939/939 logic tests, 947 expanded executions.
- M5 13-inch iPad Simulator, iOS 26.2: 939/939 logic tests plus 6/6 interface
  journeys, 945 logical tests and 953 expanded executions. Both platforms have
  zero failures, skips or expected failures.
- iPad journeys: Invoice launch, simple Mail, assigned-technician invoice-item
  editing, field-pricebook review, exact unlinked publication confirmation, and
  linked-catalog comparison. This is selected UI coverage, not the entire UI suite.
- Both workflow YAML files pass actionlint; review diff has no whitespace errors.
  The project manifest, signing settings, entitlements and stored schema are unchanged.
- The optimized universal Mac Release build succeeds. lipo verifies arm64 and
  x86_64; the only linker warning is the existing external Metal-toolchain path.
  Its log is retained as `QBO Billing Lifecycle Universal Release.log` alongside
  the test evidence below. This unsigned build is not distribution acceptance.

Final original bundles:
`/tmp/GunnAireQBORefreshMac/Logs/Test/Test-GunnAire Ops-2026.09.07_04-25-40--0400.xcresult`
and `/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.07_04-27-06--0400.xcresult`.
Verified copies and matching logs are retained under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/` as
`QBO Billing Lifecycle Mac Acceptance.xcresult`,
`QBO Billing Lifecycle iPad Acceptance.xcresult`, and the corresponding `.log` files.
Test transport and customer/file data are fixtures; no live business mutation.

The preceding published catalog head 705d77e passes all four hosted jobs:
[native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34097348815) and
[backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34097348890).
That is predecessor evidence, not proof that this source passed hosted CI.

## Remaining full-goal work

Server-owned immutable accounting intents, dispatch permissions and realm-scoped
mapping storage are still required. Current native role/model guards do not
prevent modified/older clients or external QBO tools from bypassing them.
Attachment uploads still need durable uncertain-outcome reconciliation/deduplication;
not every separate attachment, direct Management create/send, payment-publication,
or Google orchestration has been migrated to this coordinator. Inactive catalog
enumeration, complete ledger/payment/settlement/return history, and historical
statements remain separate correctness work.

Signed multi-device CloudKit convergence/offline acceptance, independent staff
iCloud accounts, provider-approved embedded Tap to Pay and physical iPhone/iPad
Handoff acceptance, distribution signing, platform entitlements, approved-realm
live acceptance and production deployment remain release gates. See
COMPLETION_EVIDENCE_MATRIX.md, CLOUDKIT_WORKSPACE_IDENTITY.md and
PAYMENT_ATTEMPT_COORDINATION.md. Existing competitor coverage is not a substitute
for end-to-end evidence of these requirements.

No merge, backend deployment, signing/entitlement change, CloudKit promotion,
physical installation or live business write is included. Render follows main;
PR #18 stays open for review.
