# Native QuickBooks inventory integration

September 8, 2026. Native checkpoint following server commit `89c6ee7` and its
`2026.09.08.35` inventory publication contract. This is not a production release
or completion of the full business-suite objective.

## Native behavior

- Item creation in Management and field billing offers Service, Non-inventory
  and Inventory. Field-created inventory stays scoped to its originating work
  until administrator approval; ordinary global publication permissions do not
  change. Inventory is included in material/stock planning filters.
- Management creation and administrator review expose opening quantity/date
  and explicit inventory-asset, product-income and cost-of-goods-sold accounts
  only for Inventory. Incomplete setup can be saved offline and completed later.
  Saved accounting choices retain their company, QBO realm and environment.
  Switching those choices to a different business explicitly clears all three
  old accounts. Publication rejects a different original scope.
- Inventory creates use the shared publisher, not direct device writes or the
  service-item default accounts. The server independently verifies the exact
  active account identities and types before its one-time dispatch. No account
  creation, stock adjustment or production accounting action occurred here.
- Linking an existing item displays its current provider quantity, including
  negative stock, and explains that the proposed opening stock was not applied.
  Linked balances/accounts are read-only; truck movements remain independent.
- Ordinary price updates carry immutable Type review evidence and exclude
  quantity, date, tracking and all account fields. Inventory activation changes
  require a separate accounting workflow; they are not inferred from a price
  edit. Unsure outcomes remain in the existing publication recovery workflow.
- Local draft edits, details and receipts are included in the workflow revision
  and explicit failed-save rollback, preserving in-flight changes.
- New invoice/estimate snapshots retain the sold accounting type and QBO ID
  beside the approved price. Quantity changes preserve that evidence. A later
  type/ID change requires explicit line review. Initially offline items can
  receive their first approved QBO link; legacy snapshots remain readable.
- Reopening an item retains full unit-price/purchase-cost precision instead of
  rounding it to two decimals before an unrelated edit is saved.
- iPad catalog prices and opening quantities use the standard numeric keyboard
  so the decimal-keypad popover cannot cover item controls. iPhone retains its
  compact decimal pad. The same change covers field-billing item creation.

## Provider types and incomplete bundle work

Inventory, Group, Category and unfamiliar types no longer fall back to Service.
Native reads retain inventory/account, parent/hierarchy and bundle component
details, including repeated bundle entries and their types. Categories and
bundles cannot accidentally publish as zero-price ordinary service lines.

**Category organization UI, existing-bundle selection, and actual bundle
transaction serialization remain incomplete.** They require their own native
and server transaction integration; the new gate is not claimed as completion
of those features. Intuit does not support creating Group items via its QBO API.

## Additive persistence

CloudKit bootstrap v25 adds only optional `Item.quickBooksInventorySetupJSON`
and `Item.quickBooksCatalogDetailsJSON` strings to v24. Existing attributes and
record security grants are not changed. The schema preflight and promotion
manifest require the exact additions and reject malformed/unapproved fields.
No signed bootstrap, schema promotion or multi-device delivery was performed.

Catalog receipt projection v2 includes read-only provider details. V1 receipts
remain verifiable with their exact original digest projection. Upgrading cannot
erase divergent new details or weaken provider-time ordering, original-business,
pending-review, duplicate-identity or failed-save barriers. Receipt evidence is
not an acknowledgement that stock movements or financial events were applied.

## Qualification — local candidate

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Native Inventory.GfB0hW/`

- `PublishedSourceMac.xcresult`: 1,324 logic tests pass (1,385 parameter-expanded), no
  failures/skips, on arm64 Mac Catalyst. Includes opening-field/account/scope
  validation, shared-server creation and existing-link behavior, in-flight edits,
  rollback, sparse price updates, immutable sold identities, legacy snapshots,
  v1 receipt upgrade, actual v23/v24 SQLite migration, and a real SQLite reopen.
- `PublishedSourceTools.log`: 42 release/CloudKit/device-tool tests pass. `compileall`,
  workflow lint and diff checks pass.
- `PublishedSourceUniversalMac.xcresult`: unsigned optimized Mac Catalyst Release
  builds successfully; `lipo -verify_arch arm64 x86_64` passes. Only the existing
  missing optional Metal-toolchain search-path linker warnings remain.
- `PublishedSourceIPad2.xcresult`: all 1,324 logic tests and six selected UI
  journeys pass on the 13-inch M5 iPad Simulator, iOS 26.2, with no failures
  or skips. UI coverage: inventory creation/reopen, ordinary taxable item
  creation, technician-item review, Invoice launch, simple Mail, and saving
  the original invoice and estimate offline. App and logic source match the
  Mac qualification; the final UI-only isolation correction is included here.

Retained early failures: `Compile.xcresult` identified Swift's reserved `Type`
property name and actor-boundary warnings; the corrected `ItemType` CodingKeys
and main-actor model extension compile. `Focused.xcresult` identified incorrect
optional chaining in a new test; its correction passes the 71-test focused run.
No existing failure gate, assertion or selected hosted journey was removed.

Retained iPad failures: `FinalIPad.xcresult`, `FinalIPad2.xcresult` and
`InventoryUI3.xcresult` expose a real decimal-keypad popover blocking the item
type control. The recorded UI and `FailedInventoryUI2/FailureFrame.png` were
inspected; Escape was not a reliable fix. The native iPad keyboard change above
passes `InventoryUI4.xcresult` with all exact price/quantity/date assertions
retained. Its three screenshots were inspected: the type control is unobstructed,
the saved setup is intact, and no account-email footer or internal receipt data
is displayed. Final-source platform qualification is tracked separately above.

`PublishedSourceIPad.xcresult` additionally exposed test-isolation debt: the new
test located the catalog by the label "Browse 1 active item", while its saved
inventory item survived earlier test launches. The test now uses the existing
`CompanyPricebookDisclosure` accessibility identifier and the existing scoped
test-draft cleanup convention, then selects its exact item name. No production
reset or broader cleanup was added; exact saved-value and return-navigation
assertions remain unchanged. This failure is retained separately from the real
keyboard defect; the final full-logic/six-journey rerun passes without clearing
the simulator's saved catalog. Its evidence is in `InventoryIsolationFailure/`.
The final saved-item and keyboard screenshots in `FinalInventoryScreens/` were
visually inspected: the original values remain intact, the control is clear,
and no account-email footer or internal receipt data is shown.

The GitHub workflow adds this inventory journey and technician-item review,
bringing selected iPad journeys from 31 to 33 without removing prior tests.
Preceding head `89c6ee7` passes both hosted workflows; these new changes require
their own exact-head hosted qualification after publication.

## Remaining release and full-goal gates

Qualify signed CloudKit bootstrap/promotion and actual two-device sync; then
concrete sandbox and authorized production provider
acceptance against the matching backend. Do not merge/deploy based on these
fixture results. The broader competitor feature matrix, Google/vendor coverage,
tenant/role acceptance, Handoff/Tap to Pay, bundle/category workflows and physical
release acceptance remain part of the active objective.

## Primary references

Rechecked in Safari September 8, 2026:

- [Intuit Item API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/item):
  conditional inventory fields, read/update date distinction, categories,
  repeated bundle components and Group creation limitation.
- [Intuit Account API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/account):
  exact account classifications (also verified in the preceding server work).
- [Apple numbers-and-punctuation keyboard](https://developer.apple.com/documentation/uikit/uikeyboardtype/numbersandpunctuation):
  the standard numeric keyboard used for the iPad catalog fields.
