# Field-created items and QuickBooks publication

September 7, 2026. Native implementation checkpoint; not production or
whole-application acceptance.

## Workflow and authority

Technicians keep creating job items locally. Administrator pricebook approval
remains separate from provider publication. The invoice keeps its original
line snapshot and sold price; successful catalog publication supplies the
QBO Item ID without repricing that invoice. No invoice is automatically sent
or created by the catalog action.

The active QuickBooks Management approval/retry, linked comparison, catalog
update and Use QuickBooks Version actions now share QuickBooksCatalogWorkflow.
The service captures its API connection and run before scheduling, keeps its
original ModelContext, checks current known administrator access, and checks
the exact item/approval revision after reads and before local commits. A
one-shot run cannot dispatch twice or replace an already active catalog action.
The view cancels its catalog run when dismissed and does not allow a general
resource import to race the reviewed proposal.

An open publication confirmation retains all provider-owned item fields and
approval identity, not only its visible name/price. An edit, replacement
connection, duplicate local identity or changed authorization invalidates it.
Both reconciliation directions re-read the same QBO ID and require the exact
reviewed provider version; changed SyncToken or values require another review.
Displayed comparison rows retain their provider-context owner. Offline users
can review saved differences but must reconnect before choosing a direction.

## Preservation and recovery

- A unique existing name/SKU/type match can be linked without a create. A
  missing/different SKU is no longer treated as a wildcard. Conflicting names,
  SKUs or types stop automatic linking and creation.
- The create uses the existing stable item request ID and captured matching
  realm/environment accounting configuration. Provider replay with different
  prices stages reconciliation and preserves the approved local proposal.
- Late responses cannot overwrite edited/deleted/replaced items or assign a
  QBO identity already owned by another local record. Invoice line recovery
  also rejects duplicate local UUIDs instead of picking the first record.
- A possible write followed by failure is described as unconfirmed, not as
  proof that QBO rejected it. Failure status is saved only in the still-valid
  original item/context and does not advance its last successful sync date.
- Failed local saves restore the fields this workflow changed, including
  unlinked supplier names and original approval metadata. Unrelated business
  records are not rolled back or deleted.
- The existing pricebook, catalog comparison and waiting-invoice queues are
  reused. No extra tab, dashboard, SwiftData field or CloudKit schema is added.

Intuit's [API best-practices guidance](https://blogs.a.intuit.com/2018/09/10/quickbooks-online-api-best-practices/)
describes replay by request ID. That is not treated as an indefinite
cross-device dispatch guarantee. The current interactive Item/request-ID
reference pages did not expose readable contracts in this check. Existing
endpoints and query/ID formats are unchanged; no new provider limit or
retention period is assumed.

## Verification

Final current-source acceptance on Xcode 26.6 (17F113):

- M5 13-inch iPad Simulator / iOS 26.2: **903/903 logic tests and 10/10
  selected interface journeys pass**, zero failures/skips (913 logical tests,
  921 parameter-expanded executions).
- arm64 Mac Catalyst: **903/903 logic tests pass**, zero failures/skips.
- Unsigned optimized universal Mac Catalyst Release succeeds; lipo verifies
  arm64 and x86_64. The existing external Metal-toolchain search-path warning
  remains. No app compile errors were reported.
- The ten iPad journeys cover Invoice launch, simple Mail, technician invoice
  item editing, field pricebook correction/approval, linked comparison,
  explicit publication confirmation, offline pricebook editing/creation,
  choosing a freshly checked provider version, and offline direction gating.
- Both workflow YAML files pass actionlint. Changed files match the
  authoritative workspace; the project manifest and stored schema are unchanged.

The final runs use the GunnAire Ops scheme, serial tests and
CODE_SIGNING_ALLOWED=NO. Retained evidence under
/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/:
QBO Catalog Lifecycle iPad Acceptance.xcresult,
QBO Catalog Lifecycle Mac Acceptance.xcresult, matching acceptance logs,
and QBO Catalog Lifecycle Universal Release.log. Full Xcode invocations are
recorded in those logs. These are fixture/simulator and unsigned Mac checks,
not signed-device, live QBO or whole-interface acceptance.

The first compile found an actor-isolated default test argument; the next
focused run exposed lifecycle ownership in standalone service calls. The
service now retains its lifecycle owner. The focused 26-test run and the
following 902-test/10-UI pass preceded the final invoice-catalog merge fix and
its additional regression. Final acceptance includes all **27 new logic tests**.
Intermediate failures are retained separately from final acceptance.

The dedicated suite covers create, read-only link, old-price replay, exact
confirmation invalidation, field-item approval through invoice line mapping,
account replacement, item edits before/after dispatch, cancellation, revoked
roles, overlapping runs, duplicate local/provider identities, reviewed-version
updates, provider-version application, local-save rollback, unconfirmed-response
recovery, accounting realm mismatch and invalid values. Provider requests use
injected fixture transports and in-memory stores, never real business endpoints.

Prior head 529fe26 passes both [hosted native jobs](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34093728868)
and both [Backend matrix jobs](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34093728884).
Those results qualify the preceding resource-sync checkpoint only.

## Still required for the full goal

Publication still originates on the client. A server-owned, immutable catalog
intent/dispatch journal, durable realm-scoped item mappings, cross-device
concurrency/reconnect review and complete inactive-item enumeration remain
required. Query-before-create plus a stable request ID is not proof of
indefinite exactly-once behavior after process loss, provider retention expiry
or a changed proposal on another device.

Other customer/vendor/document publication and Google/attachment workflows
still need their full retained-context audits. In particular, the separate
BillingDocumentsView.prepareQuickBooksItemsForDocument / ensureQuickBooksItems
callback chain remains an active catalog-create path inside customer/invoice
publication. It is not qualified by the Management service tests. Its full
customer → items → invoice/estimate → local-save operation must be migrated
together; its catalog merge now preserves duplicate identities for the shared
line-policy guard, but that alone does not fix the entire callback lifecycle.
Event-specific deleted/voided
and payment-allocation reconciliation, historical accounting, payment
settlement/returns, administrative identity resolution, signed CloudKit
multi-device/offline convergence, production provider approval and physical
iPhone Tap to Pay/Handoff acceptance remain open. The ten-suite feature
inventory is not proof that all workflows are flawless.

No merge, deployment, signing change, physical install, production schema
promotion, live accounting mutation, charge or customer message occurs in this
checkpoint.
