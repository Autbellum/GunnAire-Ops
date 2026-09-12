# Shared customer publication — candidate 2026.09.07.24

This advances the customer phase required by invoice and payment publication.
It does not complete server-owned invoice/estimate/payment sending or the full
business-suite goal. Nothing has been deployed or sent to live QuickBooks.

## Native workflow and permissions

Production `recoverOrCreateCustomer` now uses the shared publisher; supplied
device snapshots cannot bypass its customer census or one-to-one mapping.
Production `createCustomer` rejects direct writes. The Billing Documents
customer preparation phase explicitly uses the server even when a device could
find a matching customer. Legacy direct transports remain isolated test fixtures.

The server uses the existing administrator-only company customer-sync policy.
There is no primary-email bypass. Accounting, dispatch and field users can keep
their local documents, but must ask an administrator to establish a missing
accounting customer link before publication. This resolves the previous implicit
customer-create side effect in document/payment workflows; it does not remove
technicians' saved line items or ability to edit their assigned field invoice.
Authoritative server work-order grants remain necessary for more delegated
customer/billing dispatch; client-submitted assignment claims are not sufficient.

**Customers → customer record → Overview → Customer Actions → Customer sync
review** opens a focused page within the current navigation stack. It shows the
original customer's name, a short state and recovery/cancellation actions, not
payloads or provider diagnostics. Back returns to the same customer record and
scroll position. Recovery only reads the original server attempt and customer.
Cancellation requires confirmation and only releases a never-sent proposal.
No customer, job, invoice, file or provider record is deleted.

Single-customer Sync and recovery capture the original workspace, role, exact
model instance, UUID, contact values and prior QBO ID. Edits, deletion, duplicate
UUIDs, replaced accounts, cancellation and revoked access reject late results.
Link confirmation cannot overwrite a different existing QBO ID or another local
customer's mapping. Failed local saves restore just the link, not unrelated
unsaved work. Contact details are never silently replaced during recovery.

The API completion is delivered once under its original captured scope, even if
the callback finishes that owner. Backend-mediated mutations preserve the same
uncertain-write risk as direct provider requests. Existing directory-batch and
Management callback orchestration, and already-linked legacy customer adoption,
still need broader retained-model/mapping review; migrating the central create
transport is not proof that every higher-level customer path is complete.

## Server contract

- `POST /api/customer-publications`: exact `companyID`, `realmID`, `environment`,
  `localCustomerID`, and supported `customer` contact fields.
- `GET /api/customer-publications?companyID=…&localCustomerID=…`: scoped status.
- `POST /api/customer-publications/{id}/recover` with `{}`: verification reads
  only, never a new dispatch.
- `POST /api/customer-publications/{id}/cancel` with `{}`: cancel only `reserved`.

Every operation requires a current opaque application session, an active server
administrator, the exact server company and QBO realm/environment, and the
original authorization grant. Role/grant checks repeat after provider reads and
inside the transaction immediately before sending. Raw provider identity tokens
and shared deployment tokens cannot authorize the contract.

Payloads allow only DisplayName, PrimaryPhone, PrimaryEmailAddr and the existing
single-Line1 billing address. No Balance, Id, SyncToken, parent/job reassignment,
arbitrary URL, financial field or update/delete action is accepted. The server
owns `Notes: GunnAireCustomerID:<local UUID>` on its new creates. Names/contact
formats and provider limits are validated before reservation. Customer update,
merge, hierarchy and structured multi-line address support remain separate work.

Encrypted, canonically hashed immutable intents retain their original stable
`ga-customer-<UUID>` request ID. A unique open-intent index serializes one local
customer, while hashed normalized names serialize conflicting concurrent local
proposals. Company/realm/environment-scoped one-to-one mappings prevent another
local UUID from adopting the same QBO customer. Reservation, dispatch, mapping,
confirmation, cancellation and their audit records are transactional.

Customer census explicitly includes active **and inactive** entities, checks
counts before/after pages, checks page position/size and rejects repeated IDs.
The comparison is bounded at 100,000 customers and 1,000 per page. It is not a
transactional QBO snapshot or an external-accounting-tool lock. Ambiguous names,
conflicting contacts or a foreign GunnAire marker stop publication. Existing
compatible customers can be linked without a POST; inactive links are retained
server-side for review but cannot be used by the native publisher for new billing.

The adapter uses only fixed Intuit accounting origins and customer/query
resources, bounded response bodies, no redirects and an in-memory refreshed
bearer. The original-grant compare-and-set mechanism protects refresh. Dispatch
is claimed atomically after refresh and immediately before POST. A timeout,
malformed response, role loss or confirmation-save failure leaves `sending` or
`unknown`; neither state can resend or be cancelled. Read-only recovery from
those states requires the original server marker and matching supplied contact
values, not merely a same-name customer. Absence does not prove it is safe to
create another customer. A confirmed replay rereads the exact provider ID and
never creates a second customer after a local name/contact change.

Public status omits contacts, actor email, request ID, grant fingerprint and
encrypted payload. Customer responses expose only the contact identity and
active status needed for linking, not provider tax identifiers, balances or
private notes. No raw provider errors enter user-facing diagnostics.

## Primary contract references

Read in Safari on September 7, 2026:

- [Intuit Customer](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/customer):
  create/read, DisplayName uniqueness, field constraints, active status and Notes.
- [Intuit query syntax](https://developer.intuit.com/app/developer/qbo/docs/learn/explore-the-quickbooks-online-api/data-queries):
  explicit active/inactive enumeration, COUNT, ORDERBY, STARTPOSITION and MAXRESULTS.
- [Intuit identity and request IDs](https://developer.intuit.com/app/developer/qbo/docs/learn/learn-basic-field-definitions):
  realm identity, stable request/content replay and the 50-character request limit.
  No indefinite idempotency-retention guarantee is assumed.
- [Apple sheets](https://developer.apple.com/design/human-interface-guidelines/sheets):
  scoped tasks, clear return navigation and avoiding nested modal stacks. The
  customer review therefore pushes inside the existing customer navigation.

## Verification

Final source passes **1,100/1,100 logic tests on each of Mac Catalyst and the
13-inch M5 iPad Simulator (iOS 26.2), 10/10 selected iPad UI journeys, 216/216
Backend tests and 37/37 Tools tests**, zero failures or skips. The
first focused Mac run passed the existing billing suite; the next passed 53
customer/billing tests. Two additional actual billing-coordinator tests verify
server customer identity → preserved sold invoice lines, and office-approval
denial → retained field draft with no invoice POST.

The ten iPad journeys cover customer sync cancellation/return, original-link
recovery, assigned-technician invoice-item editing, field billing/pricebook
separation, focused customer workspaces, saved account statements, catalog
publication review, billing identity review, direct Invoice launch and simple
Mail. These ten differ from the fourteen hosted workflow selections; neither
selection is a fresh complete UI target or a physical-device acceptance run.

The optimized unsigned universal Mac Release succeeds; `lipo` verifies arm64
and x86_64. Only the existing external Metal-toolchain search-path linker
warning remains. Executable SHA-256:
`b5046a63bdb8517ff3addb08379b4b7206613927234a6654adcdd304dc693466`.
New customer UI fixture flags/data are absent from that Release executable.
Both workflow files pass actionlint, Xcode recognizes the unchanged shared
scheme and both selected destinations, and whitespace checks pass.

Final original result bundles:

- `/tmp/GunnAireQBORefreshMac/Logs/Test/Test-GunnAire Ops-2026.09.07_10-10-27--0400.xcresult`
- `/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.07_10-05-37--0400.xcresult`

Verified copies, logs, the unsigned Mac artifact and two individually inspected
final customer-review screenshots are retained under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/QBO Customer Publication/`.
The screenshots show readable status, original customer context, Back/Refresh,
and no clipping, nested modal, raw provider metadata or account-email footer.
The preceding `7d18532` head passed all four hosted jobs; this candidate still
requires its own new-head checks. Nothing was merged or deployed.

The first focused iPad run passed 55 logic tests and the recovery UI journey.
Cancellation succeeded and Back returned to the customer, but its final test
asserted an offscreen lazy workspace picker existed without scrolling. The exact
screen/result was retained and the test corrected to scroll to the picker and
verify Overview remains selected. This initial failed run is not acceptance.
Initial result: `/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.07_09-59-22--0400.xcresult`.

The native source has no model/schema, project-manifest, deployment-target,
signing, entitlement or provisioning change. Debug-only UI fixtures do not read
real credentials or contact providers and compile out of Release.

## Deployment, CloudKit and remaining goal

Review, back up, deploy and verify backend **2026.09.07.24** before distributing
this candidate. Older services cannot satisfy the new customer publication
contract; the app does not fall back to direct QBO creation. Preserve all three
new tables (`customer_publications`, `customer_publication_keys`,
`customer_entity_mappings`), indexes and the existing encryption key in backups
and code rollback. Do not delete an unknown attempt or restore an old database
to enable a resend. Use one authoritative transactional store, not independent
SQLite replicas. Reconnected-grant adoption and uncertain-outcome resolution
require further evidence-based administrator tooling.

CloudKit remains essential and unchanged. Cross-device journal coordination is
not proof of signed iPad/Mac CloudKit convergence, queued-write lifetime, offline
identity availability or independent employee Apple-account sharing. These remain
open in CLOUDKIT_WORKSPACE_IDENTITY.md. New customer links continue to live in
the existing SwiftData/CloudKit model; no schema promotion is included.

Server-owned invoice/estimate/payment sending, broader credential containment,
legacy mapping migration, complete ledger/settlement/history, remaining Google
workflows, supplier API onboarding, approved embedded Tap to Pay and physical
iPhone Handoff, Mac UI host qualification, distribution and live-provider
acceptance all remain open. No merge, deploy, signing/entitlement change,
physical installation, live accounting/payment mutation or customer send occurred.
