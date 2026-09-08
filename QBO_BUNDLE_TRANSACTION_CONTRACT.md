# QuickBooks bundle transaction integration

September 8, 2026. Backend candidate `2026.09.08.36`, following review head
`21694fd`. This is a transaction/read/recovery checkpoint, **not completion of
bundle creation in the invoice builder or the full business-suite objective**.

## Provider contract verified in Safari

- [Intuit bundle workflow](https://developer.intuit.com/app/developer/qbo/docs/workflows/manage-inventory/item-bundles-using-groups)
  explicitly supports sales transactions with a `GroupLineDetail`, its group
  reference, `Quantity`, and nested sales-item lines. The official response
  example has a zero-amount group header. Components carry their own extended
  quantities, prices, amounts and tax choices. Do not multiply them again on
  publication, sum the header as another charge, or replace the group with a
  zero-price service item.
- [Intuit Item API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/item)
  permits repeated entries in a bundle; nested bundles and categories are not
  components. Group catalog creation, update and deactivation are QBO-UI-only.
  Transaction members can be removed or changed while retaining the group.
- [Intuit Invoice API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/invoice)
  defines `GroupItemRef`, `Quantity` (not `Qty` on the header), and nested `Line`.
  This contract conservatively counts all headers, components and the final
  discount toward the 750-line limit. Requests retain explicit saved component
  prices instead of asking QBO to expand today's pricebook silently.
- [Apple disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)
  support retaining the common information visibly while revealing related
  details on demand. Billing Review shows the bundle's component total and
  quantity, with ordered components in an expandable section, without raw
  accounting references or an email footer.

## Implemented server paths

- Strict create/update validation accepts true groups alongside ordinary sold
  lines and one final discount. Empty groups, recursive groups, conflicting
  detail types, self references, malformed money, nonfinite/negative/zero
  quantities, unsupported tax choices, and incomplete member arrays fail.
- Group headers normalize an omitted amount to zero; a nonzero header is not
  accepted as a second billable charge. Component amounts round once to cents;
  quantity and unit-price precision remain up to five decimals. Order and
  repeated item references are retained in encrypted immutable proposals.
- Every group and every unique sold component must have a shared mapping in
  the original business, realm and sandbox/production environment. Provider
  preflight reads each unique identity once and verifies its actual active
  type. A taxable member triggers the same automated-tax/address checks as a
  top-level taxable item, regardless of the group's catalog tax flag.
- A technician with a current server-recorded assignment can publish the
  current ordered bundle recipe at the current leaf prices/tax choices. A
  changed recipe, removed member, quantity exception, changed price/tax or
  discount requires an exact office-reviewed draft grant. The server does not
  overwrite the saved sale with today's catalog values. Office-reviewed
  transaction customization remains supported; the catalog itself is not
  edited by a transaction.
- Existing Group item link review includes recipe and display-choice evidence.
  A recipe change invalidates confirmation even if the provider leaves the
  SyncToken unchanged. Confirmation creates only the scoped shared mapping,
  never another QBO catalog item.
- Create, unpaid invoice update, confirmed replay, unknown-result recovery and
  mapped-document reads use the same complete group parser. Nested provider
  row IDs must be unique across the entire document. Subtotal, tax, total and
  balance reconciliation counts each component charge exactly once. Changed,
  missing or reordered components cannot confirm the original request.
- Public results retain only the sold fields, not member account references,
  provider metadata or tax identifiers. A lost/invalid response stays unknown;
  recovery checks the original attempt and does not send another invoice.

## Implemented native paths

`QuickBooksLineItem` now retains actual group details and provider line IDs.
Its encoder emits a real group payload without a dummy sales-item detail.
Nested groups and conflicting detail types are rejected during decoding.
An absent zero-charge header differs from a missing or malformed leaf amount.

Shared native validation now covers proposal preparation, confirmed responses,
mapped billing context and original-line comparison. It validates component
quantities/prices/tax, group identity, duplicate provider rows, cumulative line
limits, discount amounts and complete totals. Original proposals retain the
same encrypted journal version and scope-associated encryption. No new SwiftData
attribute, CloudKit field, entitlement or signing setting was added.

Billing Review renders a bundle as its real component sum; its expandable
members retain repeated entries and show their own quantities, prices and tax
choices. Review/cancel does not create an invoice, email a customer, or collect
payment. The dedicated UI fixture represents an original server proposal that
differs from the local draft; it does **not** assert that native bundle selection
or editing is complete, and it has no accounting publish transport.
Displayed unit prices retain two to five decimal places, so a saved $12.375
rate does not appear as $12.38 while ordinary whole-cent prices remain compact.

## Qualification

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Bundle Transactions.x0wf6R/`

- `FinalBackend.log`: 546 tests pass, including 33 new bundle tests. Coverage
  includes real authenticated local HTTP routes through the fixed-origin QBO
  adapter with a fixture transport, original-business mappings, assigned field
  authority, exact office approval, mixed tax, edited/repeated members, existing
  Group mapping adoption, unpaid update, and recovery after catalog changes.
- `FinalMac.xcresult`: 1,341 logic tests pass across 37 suites, including the new
  native bundle contract, shared-client publication, complete response checks,
  duplicate/changed component rejection and an encrypted on-disk journal reopen.
- `Tools.log`: 42 release/CloudKit/device-tool tests pass. Python compilation,
  workflow lint and diff checks pass.
- `FinalIPad.xcresult`: all 1,341 logic tests and five selected UI journeys pass
  on the 13-inch M5 iPad Simulator, iOS 26.2, without failures or skips. UI paths
  cover bundle expansion/repeated members/total/cancellation, original ordinary
  proposal cancellation, accepted-invoice recovery, Invoice launch and simple
  Mail. `FinalBundleScreens/` contains the retained expanded/cancelled views.
- `FinalUniversalMac.xcresult`: unsigned optimized Release builds successfully;
  `lipo -verify_arch arm64 x86_64` passes. Existing optional Metal-toolchain
  search-path linker warnings remain; no new source warning is introduced.

Earlier successful `FullMac2`, `IPad` and `UniversalMac` results predate the
unit-price display refinement and are not substituted for the final evidence.
The expanded and cancelled iPad screenshots were visually inspected: readable
component amounts, two distinct repeated rows, and no email footer/raw IDs.

Retained failure: `FullMac.xcresult` / `FullMac.log` caught an XCTest assertion
using `XCUIElement.count` instead of a matching-element query. The corrected
query retains the assertion for two separate repeated component rows.
`InitialNative.xcresult` passed the earlier 80 billing regression tests.

## Hosted CI continuation

Prior head `21694fd` passes both Backend jobs and the native Mac job. Its native
iPad job `101973235878` in run `34198971304` ended cancelled: GitHub's check-run
annotation explicitly reports exceeding the 45-minute limit. The retained job
log shows continuing successful UI tests, including both new inventory/review
journeys, then interruption during the tax-address review. This is **not** a
completed green native run. No test assertion failure was substituted with a
timeout explanation; the original interruption and remaining journeys require
a new full run.

The workflow adds the bundle-review journey (34 total) and grants only iPad
60 minutes, retaining Mac's 45 minutes, all prior selectors, complete logic,
unsigned universal Release, read-only permissions and artifact retention. Its
candidate passes actionlint. Because the saved HTTPS credential lacks workflow
scope, the workflow is committed through the already-authorized Safari session;
no credential scope or account permission is expanded. The application changes
must then be published on top and receive their own exact-head hosted checks.

All provider writes here were isolated fixtures. No live QBO record, schema
promotion, production deployment, signing or account-permission change occurred.

## Remaining implementation — do not substitute the current gates for support

Continuation: [native bundle composition](NATIVE_BUNDLE_COMPOSITION.md) now
implements category browsing, immutable ordered selection/member edits,
customer summaries, cost/tax/stock consumers and native publication/recovery
from those saved snapshots. Its newer evidence supersedes the local-composer
gaps below, but not their signed CloudKit and concrete provider-acceptance
requirements. Progress billing, editable provider imports and mixed-version
client protection remain explicit implementation work. The list below records
the original transaction checkpoint, not a claim that these gates were waived.

1. Add category hierarchy browsing/filtering to native catalog selection, with
   exact parent identities, bounded depth and explicit missing/cyclic/ambiguous
   hierarchy handling. Categories remain organizational, never sold lines.
2. Resolve existing bundle selection to the original company's exact active
   component identities. Preserve an ordered immutable bundle snapshot rather
   than using the service-assembly dictionary that collapses repeated item IDs.
3. Connect the iPad-first invoice/estimate composer to that snapshot: reveal
   members, change group quantity with appropriate component scaling, edit or
   remove individual members while retaining the group, and obtain exact price
   approval when required. Preserve these edits on save/reopen and CloudKit sync.
4. Carry component tax, cost, stock requirements and service-equipment identity
   into document totals, inventory planning, profitability and customer exports.
   Honor the bundle's customer-facing display choice without hiding audit data.
5. Connect snapshot publication to the real group request now supported by this
   contract; verify invoice/estimate creation, update and lost-reply recovery
   end to end from the actual composer, not just the shared publication client.
6. Qualify concrete authorized QBO sandbox acceptance and signed multi-device
   CloudKit delivery. Provider restrictions on catalog Group creation remain a
   QBO handoff, not permission to fabricate an API or silently create a Service.

The original competitor matrix, broader Google/vendor workflows, access-level
acceptance, physical iPad/Mac release checks and iPad-to-iPhone Handoff/Tap to Pay
remain part of the full active objective, not waived by this checkpoint.
