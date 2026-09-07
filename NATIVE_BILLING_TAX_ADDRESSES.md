# Native billing tax addresses — September 7, 2026

## What is implemented

The job Billing stage and standalone Invoice/Estimate line editor share one
compact **Tax addresses** row when the selected lines are taxable. A focused
native form collects street, city, state and ZIP for the service location and
sale/ship-from location. The free-form original site is shown as a reference;
it is not parsed into an assumed jurisdiction. Using the service location as
the sale location is an explicit choice. Cancel does not alter the draft.
Returning to billing preserves sold line prices, quantities and discounts.

Reviewed values are retained in `catalogSnapshotJSON`, the existing stored
Invoice/Estimate snapshot. Legacy line arrays are wrapped in the existing
version-one envelope; existing envelope keys are preserved when attaching
addresses. No SwiftData entity/property, CloudKit schema, entitlement, signing,
project version or deployment setting changes. The review is bound to the
original customer, service-location ID and site snapshot. Changing that scope
requires a fresh review; a stale form closes when its scope is replaced.

The normal saved-document and Management retry coordinator sends structured
`ShipAddr` and `ShipFromAddr` for invoice creation/update and estimate creation.
The payment workflow's missing-invoice creation path uses the same address
boundary. Taxable publication rejects missing, malformed or wrong-scope review;
the main coordinator checks this before prerequisite customer/catalog writes.
Offline drafts can still be saved. A simple instruction directs the user back
to Tax addresses; no rate is invented, sold price changed, customer message
sent or payment initiated by this review.

The DTO accepts complete US addresses for the existing US/USD billing workflow.
Field validation is not postal-delivery validation or tax/legal advice.
QuickBooks remains responsible for the calculated tax and final total.
Customer approval revision hashes include the stored snapshot, so changing
reviewed address evidence invalidates that revision. Estimate-to-invoice draft
conversion preserves the original scope and address data.

## Provider evidence

Read the current [Intuit Invoice reference](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/invoice)
in Safari on September 7, 2026. Its `ShipFromAddr` definition distinguishes the
shipping origin from the sale location for work without shipping, and requires
that context for accurate automated sales tax. It also explains that omitted
shipping addresses may inherit customer defaults. This motivated explicit
review instead of guessing that a billing/default address is the service site.

## Verification

- Initial focused Mac test run: **53/53**, including ten new tax-address tests
  and five new billing-coordinator tests. Result bundle:
  `/tmp/GunnAireQBORefreshMac/Logs/Test/Test-GunnAire Ops-2026.09.07_13-21-27--0400.xcresult`.
- Final Mac logic run: **1159/1159**, zero failures/skips. Result bundle:
  `/tmp/GunnAireQBORefreshMac/Logs/Test/Test-GunnAire Ops-2026.09.07_13-42-40--0400.xcresult`.
- Final iPad acceptance: **1164/1164**, comprising 1159 logic tests and five
  selected UI journeys, zero failures/skips. Result bundle:
  `/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.07_13-42-39--0400.xcresult`.
  The tax review enters and cancels without saving, confirms complete values,
  retains the original subtotal, saves the invoice, exits Job Documentation,
  and reopens the same job with its reviewed addresses intact. Adjacent existing
  invoice editing, Invoice launch, simple Mail and pending-tax handoffs pass.
- Initial iPad run: **1159/1159 logic and 4/5 selected UI journeys pass**.
  The new review test failed after its generic Command-A helper lost keyboard
  focus in an empty field. The recording shows the field and software keyboard
  active; direct entry into the empty fields passes the subsequent attempt.
  That attempt then targeted the toggle row without activating its switch.
  The revised test scrolls the actual sheet and targets the switch thumb, while
  preserving exact field-value, confirmation, cancellation and price assertions.
  A third attempt reached successful save but tapped an offscreen Work segment.
  The final test instead exits and reopens the actual job. Earlier failed
  attempts are retained as test-interaction diagnostics, not counted as passes;
  none of the app's validation or price-preservation guards were relaxed.
- Optimized unsigned universal Mac Release passes; `lipo` verifies arm64 and
  x86_64. Executable SHA-256:
  `0314ece2f4ec5cdc8c888ff06b9fffe4ab805fa8468479c4ec3b31c78d93cddd`.
- Both unchanged workflow YAML files pass actionlint.

Final evidence is retained under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Billing Tax Addresses/`.
`MacFinalAcceptance.xcresult` and `iPadFinalAcceptance.xcresult` contain the final
runs. The final iPad attachment in `Final iPad UI/` was visually inspected:
normal focused native form, readable fields, explicit sale-location switch,
Cancel/Use addresses actions, and no account-email footer. The keyboard remains
visible because this captures address entry, not an App Store screenshot.

The source/test groups in `/tmp/GunnAireQBOBuild.LvvxSD` point to the original
iCloud project. Both Debug runs use scheme `GunnAire Ops`, signing disabled,
serial execution and the complete `GunnAire OpsTests` target. Mac destination is
`platform=macOS,variant=Mac Catalyst,arch=arm64`; iPad is M5 13-inch/iOS 26.2
simulator `147D4CB6-85CC-4B17-BD35-8684E60E672D`. The optimized Release uses
generic Mac Catalyst, `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` and signing
disabled. Its app source predates only the UI-test interaction corrections,
not any runtime code change. The unchanged project manifest SHA-256 is
`52ecaabdb59c9d554d286f448a121eecd5a319afd6961bd9de62c3c075b315f7`.

Prior published head `34a6b32` now passes all four hosted jobs:
[native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34146297472)
and [backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34146297413).
Those results qualify the preceding job-billing checkpoint, not this tax-address
source. The unchanged backend remains candidate 2026.09.07.27.

Tests cover complete versus invalid addresses, legacy array/envelope round trips,
unknown metadata retention, changed customer/location/site, malformed address
metadata without loss of sold-line decoding, fresh model-context reads,
estimate-to-invoice conversion, approval-revision changes, backwards-compatible
provider DTO decoding, actual create/update/estimate request bodies, stopped
prerequisite writes, and changes during provider reads. All provider requests
use fixtures. The fresh model-context test is not signed CloudKit convergence,
cold-launch/device acceptance or a claim that account sharing is complete.

## Remaining full-app requirements

This removes an address-capture prerequisite; it does **not** claim that native
Invoice/Estimate buttons now use `BillingPublicationClient`. They still use the
retained native transport. Shared legacy customer/item/document mappings,
server publication/approval/recovery navigation, exact original proposals,
credential containment and actual native cutover remain required. Legacy
taxable drafts without address context need explicit review before publication;
immutable historical documents must not be unlocked or changed to bypass it.

The full goal also retains signed CloudKit/offline/multi-device and independent
staff-account acceptance, complete ledger/payment-event and bank settlement
history, server-owned Google draft/outbox and received-mail file linkage,
vendor contracts/onboarding, approved physical iPhone Tap to Pay/iPad Handoff,
Mac UI host qualification and production/distribution verification. The prior
competitor capability map is a requirements inventory, not proof that all
features are flawless. No merge, deployment, live accounting/payment/customer
action, signing change, CloudKit promotion or physical installation occurred.
