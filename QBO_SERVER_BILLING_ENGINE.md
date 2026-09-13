# Shared billing engine — initial stage and HTTP follow-up

**2026.09.07.29 follow-up:** the primary native publication actions now use the
engine with durable original-proposal recovery and exact office price approval.
See [NATIVE_BILLING_PUBLICATION.md](NATIVE_BILLING_PUBLICATION.md) for the current
boundary, rollout order and remaining paths. Earlier stage statements below are
historical and do not qualify deployment or full-app completion.

Current candidate **2026.09.07.26** exposes the engine through authenticated
HTTP, adds revisioned server job authority and a typed native client. See
[QBO_BILLING_HTTP_CONTRACT.md](QBO_BILLING_HTTP_CONTRACT.md) for the current
contract and acceptance. The original stage below is retained as historical
evidence. Native billing buttons still need migration; the HTTP-only gap below
is superseded, not the remaining native/CloudKit/provider acceptance work.

## Initial 2026.09.07.25 status and full-goal boundary

This is a necessary backend implementation stage, **not a completed native
invoice/estimate migration**. `BillingPublisher` and `BillingQBOProvider` are
implemented and tested together. Database startup adds their tables, and the
existing payment journal now checks shared billing reservations. No HTTP route
instantiates the publisher/provider yet. No app button uses the new engine.
Native invoices/estimates still follow the direct transport documented in
QBO_BILLING_WORKFLOW_LIFECYCLE.md. That authority gap remains open.

The next integration stage must connect reviewed HTTP contracts, native draft
submission, appropriate office/assigned-field authorization, cancellation and
read-only recovery inside the existing Billing Documents navigation. It must
preserve technician-created items and the original sold prices. The exact-draft
office grant below is one supported approval mode, not a replacement for the
required seamless, server-authorized assigned-technician workflow. Do not turn
off the current field paths without completing and verifying that handoff.

No live QBO request, customer send, payment, deployment, signing change,
CloudKit promotion or physical installation occurred. The entire suite goal
remains active; competitor feature coverage alone is not acceptance.

## Implemented contract

The internal publisher takes an exact company UUID, realm, environment,
document type (`Invoice` or `Estimate`), local document/customer UUIDs,
operation, and typed supported document fields. It supports invoice creation,
reviewed sparse invoice updates, and estimate creation. Estimate revisions,
void/delete/send, arbitrary ledger writes, and payment processing are not
accepted by this contract.

- Every action rechecks the current opaque app session, active server role,
  company, realm/environment and original authorization-grant fingerprint.
  Refresh rotation does not change the grant; reconnection requires review.
- Admin can publish either document; Accounting can publish invoices;
  Dispatcher can publish estimates. Standard users cannot publish.
- Field technicians cannot assert their own assignment or approval. The
  internal `approve_draft` operation lets an authorized office role approve
  exactly one canonical proposal hash for an active technician for seven days.
  Changed sold prices, customer, dates or notes require a new approval; approving
  a revised proposal revokes older draft permissions for that document. The
  approver must remain active with the appropriate office permission. Expiry,
  revocation and original-grant changes are checked again before sending.
- Server-owned customer and catalog mappings are required. Customer identity
  cannot be switched and an existing accounting document cannot be adopted by
  a different local record. Legacy mappings still require a reviewed migration.
- Prices and quantities use decimal validation, explicit quantity × unit-price
  rounding, bounded values, and supported US tax choices. One final fixed or
  percentage discount must reconcile. No NaN/infinity/boolean amounts, arbitrary
  opening balances, deposits, payment links or customer-send fields are accepted.
- The posting date is supplied in the immutable proposal, not silently chosen
  from the server's date on a later retry. CompanyInfo and Preferences verify a
  US business and USD home currency. Multicurrency companies require explicit
  USD document/customer evidence. Taxable proposals require configured automated
  sales tax and complete sale-origin/service addresses. Manual-tax and non-US
  contracts remain separate work; they are not silently treated as nontaxable.

## Durability, recovery and payment exclusion

Three additive tables retain encrypted, canonically hashed proposals, scoped
one-to-one document mappings and revocable exact-draft grants:
`billing_publications`, `billing_entity_mappings`, `billing_draft_grants`.
The existing encryption key is reused; no credential is added to an app or log.

One open intent is allowed per company/realm/environment/type/local-document
identity. Creates preserve `ga-invoice-<UUID>` / `ga-estimate-<UUID>` request IDs;
updates have a new server-generated request ID saved once per immutable update.
The server adds both the local document marker and an exact publication marker.
All request IDs fit Intuit's 50-character bound. No indefinite provider
idempotency-retention guarantee is assumed.

The provider refreshes authorization before the atomic one-time dispatch
claim. An uncertain, malformed or lost response retains `sending`/`unknown` and
cannot be cancelled or automatically resent. A restarted engine or restored
database can recover only through provider reads. Uncertain update recovery
requires its original publication marker, not just matching new amounts.
Cancellation applies only to a never-sent proposal and removes no business data.
Audit failures roll back reservation, dispatch or confirmation/mapping together.

Initial creation checks a bounded complete document census for legacy lineage.
Ambiguous identities, repeated IDs, incomplete pages and changing counts stop
publication. A known confirmed mapping is reread by exact provider ID. Changed
or deleted provider records do not authorize a replacement create. Confirmed
evidence must match the original customer, sold lines, billing dates, identity,
subtotal, tax, total and valid balance; extra tax identifiers and line-account
metadata are excluded from the linking response. Local addresses remain local.

The census uses documented `TxnDate` ordering, 25-document pages, a 100,000-record
bound and a 1 MiB response bound. It is not a transactional QBO snapshot. Large
histories and very large individual records need further performance/recovery
work before this becomes the normal native path. Incremental server accounting
sync and a reviewed legacy-mapping bootstrap remain required; a safe bound is
not evidence of acceptable production latency.

Invoice updates require the exact reviewed SyncToken, matching customer, a fully
unpaid reported balance, no deposit, and no payment-related linked transaction.
Existing estimate/time-activity links can remain; the sparse update does not
modify them. The existing payment journal and the new billing engine check
each other's reservations inside `BEGIN IMMEDIATE`. Matching the provider ID as
well as the local UUID prevents a duplicate native record bypass. Payment
dispatch rechecks this boundary; cancellation and outcome reconciliation remain
available. This protects the shared engine paths, **not the still-direct native
invoice writer or an external merchant/accounting client**.

## Saving does not mean sending

Current Intuit documentation says imported invoices can automatically email
customers when company auto-send settings, a customer email and online card/ACH
flags are enabled. Those flags can inherit enabled defaults. The new create
adapter therefore explicitly uses `EmailStatus: NotSet` and disables inherited
online card, ACH, Affirm and PayPal flags on new invoices. It neither calls Send
nor processes a payment. Sparse updates do not alter existing online-payment
settings. A future explicit customer-send/payment-link workflow needs its own
consent, authorization, options and duplicate-delivery tests before native
cutover; online collection is not declared complete by suppressing auto-send.

## Initial-stage verification

Final local verification: **60/60 focused billing engine/adapter tests,
276/276 complete Backend tests, 37/37 Tools tests**, zero failures/skips.
Backend, root launcher and Tools byte-compilation passes using local Python
3.9.6. Hosted Python 3.13/3.14 acceptance remains a separate exact-head gate.

Tests exercise invoice/estimate success, office role boundaries, field approval
and edits, expiry/revocation/reconnection, malformed money/references/dates,
discounts, original lineage, legacy ambiguity, changed/deleted results, encrypted
storage, response privacy, lost-create/update recovery, unsent cancellation,
audit rollback, concurrent devices, invoice/payment reservation races,
post-read/pre-dispatch mapping loss, backup/restore recovery, no-redirect and
bounded transports, US/currency/automated-tax preflight, and a full shared-engine
→ real adapter → fixture transport → confirmation → replay round trip.

The first focused run had three test-helper errors from using the wrong payment
journal class name; no provider request was involved. The helper was corrected
to the existing `PaymentAttemptJournal`, then focused and full suites passed.
Earlier 249-test acceptance preceded the additional adapter/adversarial tests;
the final result is the 276-test run, including superseded-approval rejection,
not the earlier 249- or 275-test count.

Retained evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/QBO Billing Engine/`.
Final source/test SHA-256 values and exact logs are recorded there. No Swift,
SwiftData/CloudKit schema, Xcode manifest, signing, entitlement, build number or
deployment target changed. There is no new UI or signed-device acceptance claim.
The preceding `3ba96b6` head is now verified passing all four hosted jobs:
Native `34132230042` and Backend `34132230025`. This backend checkpoint requires
its own exact-head checks. Both existing workflows pass actionlint; no workflow
edit is required because the backend suite discovers the new test modules.

## Primary sources

Read in Safari on September 7, 2026:

- [Invoice](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/invoice):
  required customer/lines, SyncToken locking, 750 taxable-line limit, posting
  dates, automatic imported-invoice delivery, online-payment defaults,
  sparse updates, computed totals/balance and tax-origin requirements.
- [Estimate](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/estimate):
  creation endpoint, customer/currency requirements and private-note limit.
- [Preferences](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/preferences):
  CurrencyPrefs and automated-sales-tax readiness.
- [CompanyInfo](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/companyinfo):
  realm-scoped read and financial country; the documented sample uses `USA`.
- [Identity/request IDs](https://developer.intuit.com/app/developer/qbo/docs/learn/learn-basic-field-definitions)
  and [query syntax](https://developer.intuit.com/app/developer/qbo/docs/learn/explore-the-quickbooks-online-api/data-queries)
  were verified for the preceding shared publisher checkpoint.

## Deployment and next acceptance

No deployment is authorized by this checkpoint. Preserve all three tables,
indexes and the original encryption key in backups. Do not restore an older
database or delete an unknown attempt to enable another write. If future billing
intents exist, older code that ignores their locks is not a safe financial
rollback: suspend publishing/collection and reconcile original outcomes first.
Use one authoritative transactional database, not independent SQLite replicas.

Next: native/HTTP integration, scalable legacy recovery, assigned-technician
server authority, signed/finalized document protections, explicit send/payment
link options, provider tax/realm acceptance, and complete financial credentials
containment. Payment-provider sending and broader accounting lifecycle events
still need server-owned dispatch. Signed multi-device CloudKit/offline
convergence, independent staff Apple accounts, Mac UI qualification, Google
outbox/document linkage, vendors and physical Tap to Pay/Handoff remain open.
