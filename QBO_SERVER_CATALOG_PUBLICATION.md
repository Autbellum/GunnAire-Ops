# Shared catalog publication — candidate 2026.09.07.23

Status: local logic, backend, selected iPad interface and optimized universal
Mac acceptance pass. This is a dependency of invoice synchronization, not
completion of the full application goal.

## User workflow

A technician's item and the price sold on an invoice remain local operational
records until the existing administrator review approves the shared pricebook.
The native approval/retry and reviewed-update coordinator now calls the backend
publisher. It does not fall back to a direct QBO POST if the service is unavailable.
Direct production `createItem` and `updateItem` wrappers also reject bypasses.
The compatibility fixture transport remains DEBUG-only and uses no credentials.

QuickBooks Management exposes **Catalog publication review** alongside pending
publication and linked reconciliation. The sheet shows just state and action,
not payloads, OAuth metadata, account emails or internal journal details.
**Recover original link** reads the original server attempt and provider result.
**Cancel unsent proposal** requires confirmation and is available only while
the server still records `reserved`. Cancel and dispatch race atomically; a
sending/unknown result cannot be cancelled or automatically resent.
Recovered older values retain the current approved local proposal for explicit
reconciliation. Existing invoice line prices are not rewritten.

## Ownership and contract

The backend requires a real, unrevoked, unexpired application session, an active
server user with Admin role, and the exact server-owned company, realm and
environment. Neither a configured primary-admin email nor a raw deployment
API key grants publication access. Role, company and original grant are checked
after provider reads and again in the transaction immediately before sending.

- `POST /api/catalog-publications`: companyID, realmID, environment,
  localItemID, operation (create/update), item.
- `GET /api/catalog-publications?companyID=…&localItemID=…`: scoped status list.
- `POST /api/catalog-publications/{id}/recover` with an empty object:
  verification reads only, never new dispatch.
- `POST /api/catalog-publications/{id}/cancel` with an empty object:
  cancels only a never-sent proposal.

The supported write payload is an explicitly reviewed Service or NonInventory
create, or a sparse update of the exact QBO ID/SyncToken, including the existing
reviewed archive/reactivation behavior. The contract rejects arbitrary fields,
URLs, nonfinite/negative/out-of-range amounts, malformed references and
unsupported item types. Unit rates may include fractional cents; they are not
silently rounded. Name, SKU and description limits follow the provider contract.

Immutable proposals are canonically hashed and encrypted using the configured
Fernet QBO storage key. The key is not written into the journal or logs.
Reservations and dispatch/confirmation/cancellation audit events are transactional.
A unique open-intent index serializes the same local item across devices/processes
sharing the same authoritative database. Do not scale to independent SQLite
replicas; a multi-instance deployment requires one shared transactional store.
Temporary hashed name/SKU/provider-ID keys prevent overlapping local proposals;
durable realm-scoped one-to-one mappings prevent a second local UUID from
adopting the same provider identity. Unsent conflicts retain the proposal for
explicit cancellation or recovery; they are not silently superseded.

## Provider verification and limits

The provider adapter allows only fixed Intuit accounting origins and bounded
Item/Vendor reads, catalog queries and Item writes. It rejects redirects and
unrelated resources. One refreshed bearer remains in memory for the request;
refresh uses the existing original-grant compare-and-set mechanism. The adapter
claims dispatch only after refresh succeeds and immediately before the POST.
It does not automatically retry a POST on timeout, malformed/non-2xx response,
reauthorization failure or local confirmation-save failure.

The complete catalog query includes active **and inactive** entities. Count,
pagination sizes/positions, unique IDs and final count are checked. Changed or
incomplete pages block a create. This is a bounded comparison (100,000 items),
not a transactional provider snapshot or an external-merchant lock. Exact
name/SKU/type matching is permitted as administrator-reviewed linking;
ambiguous or conflicting matches block publication.

A confirmed replay rereads the exact QBO Item ID instead of labelling a cached
POST response as current. Update recovery requires the current provider values
to match the immutable proposed fields; an uncertain, nonmatching update remains
for review. New updates use the fresh reviewed SyncToken. Request IDs are stable
for the original create UUID or immutable update revision and at most 50 chars;
no indefinite exactly-once guarantee is inferred from them.

Current primary documentation inspected in Safari on 2026-09-07:

- [QBO Item contract](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/item)
  — supported item fields, name restrictions, string/numeric bounds, SyncToken
  concurrency and sparse updates.
- [QBO query syntax](https://developer.intuit.com/app/developer/qbo/docs/learn/explore-the-quickbooks-online-api/data-queries)
  — explicit Active IN (true, false), COUNT, STARTPOSITION and MAXRESULTS.
- [QBO request IDs and identity](https://developer.intuit.com/app/developer/qbo/docs/learn/learn-basic-field-definitions)
  — company/entity identity and request IDs; no assumed retention lifetime.

## Verification

Final native source: **953/953 logic tests on Mac Catalyst and 953/953 on the
13-inch M5 iPad Simulator (iOS 26.2), plus 7/7 iPad UI journeys**, zero failures
or skips. Parameter-expanded device execution counts are 961 on Mac and 968
on iPad (960 logical tests including the seven UI journeys). The new sheet's
full-screen 2064 × 2752 capture was visually checked: item context, readable
status, Close/Refresh, no clipping, raw payload, account-email footer or spinner.

The final results and logs are retained under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/`:

- `QBO Shared Catalog Final Mac Acceptance.xcresult` and matching `.log`.
- `QBO Shared Catalog Final iPad Acceptance.xcresult` and matching `.log`.
- `QBO Shared Catalog Backend Acceptance.log`.
- `QBO Shared Catalog Tools Acceptance.log`.
- `QBO Shared Catalog Final Review iPad.png`.
- `QBO Shared Catalog Final Universal Release.log`.

Original exact-result paths:

- `/tmp/GunnAireQBORefreshMac/Logs/Test/Test-GunnAire Ops-2026.09.07_05-33-54--0400.xcresult`.
- `/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.07_05-33-55--0400.xcresult`.

The final unsigned optimized Mac Release succeeds; `lipo` verifies arm64 and
x86_64. Executable SHA-256:
`73faebb7914e875ebcd9549a349a83d544e7eeeac129cc355b6458e2fc92e75a`.
Only the pre-existing external Metal-toolchain search-path warning remains.
Both GitHub workflow files pass actionlint. The project manifest, signing,
entitlements and stored SwiftData/CloudKit schema are unchanged.

The iPad journeys cover Invoice launch, simple Mail, assigned technician
item editing/updating an invoice, field-item review/document priority,
unlinked publication confirmation, both linked reconciliation directions,
and cancelling a never-sent server proposal then returning to the catalog.
These are focused simulator checks, not fresh whole-UI or signed-device
acceptance. The fourteen new native tests exercise the actual coordinator
using an injected shared publisher; all provider mutations remain fixtures.

Backend: 173/173 tests pass, including 34 catalog journal/HTTP tests and 15
provider-boundary tests. The focused catalog plus existing payment-provider
suite passes 57/57 in the review clone. Tools: 37/37 pass. Fixtures cover concurrent devices, restart
after lost response, grant/role/mapping changes, inactive/ambiguous identities,
encryption/integrity, immutable values, local confirmation failure, unsupported
HTTP actions, pagination changes, resource allowlists and redirect rejection.

The first native catalog-only run passed 27/27. Subsequent expanded builds
exposed a test-initializer argument-order compatibility issue and an invalid
XCTest lastMatch usage; both were corrected. Those failures are retained, not
reported as acceptance. Final native results and visual evidence are recorded
above. The next focused run passed
75/75 catalog/billing tests. Final response review added two explicit regressions
against replacing an already-linked provider ID; Mac then passed 953/953 logic
tests and the isolated iPad recovery flow passed 14/14 logic plus 1/1 UI.
The first wider iPad run passed 951 logic and six existing UI journeys but
failed the new test because it selected a covered parent button instead of the
visible confirmation. The captured accessibility tree identified the exact
confirmation sheet. The selector was scoped to it, and the dialog now captures
the selected proposal through dismissal. No failure was skipped or suppressed.
The optimized build additionally identified an actor-isolated default argument.
Live-client construction was moved into the main-actor initializer, and complete
native acceptance was rerun after the correction; the warning was not suppressed.

Apple's [sheet guidance](https://developer.apple.com/design/human-interface-guidelines/sheets)
was read in Safari on 2026-09-07. The review is a single scoped page, returns to
its parent, shows the captured item name, and uses Close instead of implying
that dismissing the sheet saves a new publication. The full-source UI results
and screenshots above are the acceptance evidence, not this guidance alone.

## Release and remaining full-goal work

Do not distribute this native candidate until backend 2026.09.07.23 is reviewed,
backed up, deployed with the existing encryption key, and verified on an approved
realm. No deployment or live accounting mutation was used for this work.
Migration is additive: catalog_publications, catalog_publication_keys and
catalog_entity_mappings plus indexes. Retain all three tables and their key
during backup/restore and code rollback. Do not delete uncertain attempts to
clear an error. A restored older database is not proof that later provider
writes did not occur.

This endpoint controls the migrated app catalog entry paths; it does not revoke
previously issued accounting credentials or prevent old/modified clients or
external QBO tools from writing. Broader credential containment, server-owned
customer/invoice/estimate/payment/accounting dispatch, authoritative work-order
assignment for new technician invoices, and durable attachment recovery remain.

An original grant that was replaced cannot currently resume its old intent;
administrator evidence-based grant adoption/outcome resolution remains open.
No missing provider result is taken as evidence that it is safe to resend.
Independent personal iCloud business replicas, signed multi-device/offline
convergence, complete settlement/ledger history, remaining Google workflow
lifecycle work, vendor onboarding, embedded Tap to Pay provider/entitlement,
physical iPhone acceptance, and distribution/platform acceptance remain open.
The full business suite is not yet proven production-ready.
