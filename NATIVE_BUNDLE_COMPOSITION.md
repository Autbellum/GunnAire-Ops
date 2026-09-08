# Native category and bundle composition

September 8, 2026. Continuation of the shared transaction contract at `5d16fb8`.
The full iPad-first business-suite objective remains active. This native feature
checkpoint is not a production, CloudKit, provider, or distribution approval.

## User workflow and accounting meaning

The existing invoice/estimate builder's Browse Catalog action exposes category
paths from exact QBO parent references. Categories organize products; they are
not billable lines. Missing, cyclic, ambiguous, too-deep, or cross-company paths
remain discoverable under All Categories with a review label. A category index
is built once per render, rather than repeatedly for every filtered product.

Selecting an existing QBO bundle requires current versioned catalog receipts
for its original business, realm and environment and every active, approved
member. Selection freezes ordered sold rows, with a UUID for each occurrence;
the same product may occur twice without collapsing into a dictionary entry.
The zero-price group header is not a charge. Its total is the sum of individually
rounded member charges, with quantities and unit prices up to five decimals.

Included Items keeps details collapsed until requested. Group quantity scales
the already-saved component quantities; removed rows stay removed. Each member
can be edited or removed independently, but the final member cannot be removed
without removing the entire bundle. Price/tax changes require current office
authority and an explicit reason. Field users can change quantities; the
existing server still requires exact office approval for a changed recipe.
Changing a document does not mutate the shared QBO bundle catalog.

The billing root owns one editing request and presentation, outside lazy rows.
Saving checks that the selected snapshot and original business have not changed
while the editor was open. Touch targets are independent and at least 44 points
in the view layout. Missing member identity never opens a different editor.

## Durable data and connected consumers

`CatalogLineItemSnapshot.bundle` is optional JSON inside the existing
`catalogSnapshotJSON` field. No SwiftData/CloudKit attribute or entitlement is
added. It retains member identities, quantity, pricebook/authorized price, cost,
tax, stock tracking and serviced-equipment evidence, plus original QBO scope and
customer display choice. Reopening uses the saved members rather than today's
recipe or prices. Invalid or duplicate root evidence cannot silently become a
new empty draft; replacing all lines requires an explicit action.

Member leaves feed tax eligibility, invoice subtotal, document discount, price
audit, job material requirements and profitability. Stock planning sums actual
member quantities once, including repeated products; it does not multiply by
group quantity again. Customer summaries honor PrintGroupedItems without
discarding internal evidence. Concise customer system labels omit serials;
the immutable snapshot and QBO descriptions retain the exact serial/context.

Changing the customer retargets or clears equipment on the header and every
member. Same-customer reopening preserves the original saved system evidence.
The actual estimate-to-invoice factory copies the complete snapshot and resets
tax status through the existing tax policy.

Publication maps the frozen snapshot to a real GroupLineDetail and ordered
SalesItemLineDetail members. All catalog identities and the original business
are revalidated before any provider preparation. Shared publication and
lost-reply recovery retain the original prices and cannot send a second copy.
The picker refresh now receives the versioned shared Item history and commits
through the existing guarded local importer; it no longer uses the old
undated callback import or unknown-type-to-Service fallback.

## Current qualification and retained failures

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Bundle Composer.lRSoLR/`

Final corrected source:

- `QualifiedMac.xcresult`: 1,365 logic tests in 38 suites, no failures/skips.
- `QualifiedIPad.xcresult`: 1,365 logic tests plus all eight selected interface
  journeys, 1,373 results with no failures/skips on the 13-inch M5 iPad Simulator,
  iOS 26.2. Covers all three bundle input paths, Invoice launch, simple Mail,
  ordinary document saving, original bundle review/cancel, and tax-address
  editing/reopening/return. The exact execution verifier accepts all nine
  selectors (one full logic target and eight named UI methods).
- `QualifiedUniversalMac.log`: unsigned optimized Release succeeds; both
  arm64 and x86_64 architectures are verified. The existing optional Metal
  toolchain search-path warnings remain; no new source warning is introduced.
- `FinalTools.log`: 51 tests pass. `Backend.log`: 546 tests pass. Python
  compilation, workflow actionlint and diff checks pass.
- `QualifiedSource.sha256` records all 20 changed/new Swift and Python source
  files. Their contents are byte-verified in the original iCloud project and
  review worktree; unrelated original-worktree changes and its index are kept.

The actual saved/editing screenshots in `FinalInvoiceScreens`,
`TouchInputScreens` and `HardwareCorrectedScreens` were inspected. Bundle
details are readable, the Create Item disclosure remains closed, totals match
the saved components, and no account-email footer or raw accounting payload is
shown. The first two image sets predate only the numeric-keyboard correction;
the hardware set uses the corrected source. This does not claim full app visual,
VoiceOver, Dynamic Type, physical-keyboard or mixed-device acceptance.

Earlier qualification and diagnosis (not substitutes for `Qualified*`):

`FinalMac.xcresult` passes 1,365 logic tests across 38 suites. This includes
selection, repeated positions, precise cents, scope/identity rejection,
independent member editing, four-level categories, equipment retargeting,
separate SQLite container reopening and actual estimate-to-invoice conversion,
plus real native publication workflows through isolated shared transports.
Actual reporting checks cover both known and missing member costs, independent
of changed current catalog prices. The earlier `FullMac2` result predates the
final catalog-render and sheet-ownership adjustments and is not substituted for
this final-source result.

`TouchInputIPad.xcresult` passes all 22 bundle composition logic tests and the
complete estimate journey: normal Save taps with both quantity fields still
active, independent repeated-member editing/removal, persistence of the edited
total, and return to the original Sales workspace. The unrelated Create Item
disclosure stays closed. `FinalIPad.xcresult` then passes all 1,365 logic tests
and seven full UI journeys (1,372 results, zero failures/skips): both bundle
composers, Invoice launch, simple Mail, ordinary invoice/estimate save, original
bundle review/cancel and tax-address editing/return. `FinalUniversalMac.log`
passes unsigned Release with both arm64 and x86_64 verified. These results
precede the final keyboard-type correction and are retained, not substituted
for the corrected source's `Qualified*` reruns.

`HardwareKeyboardIPad3.xcresult` passes the complete third bundle journey:
Command-A selection, replacement with unmodified hardware keys, then normal
Save taps with each field still active; edited document save/return assertions
are unchanged. Bundle fields now reuse the existing catalogNumericKeyboard
policy: standard numbers/punctuation on iPad, decimal pad on iPhone. The failure
was reproduced before that correction in `HardwareKeyboardIPad2.xcresult`.

`Backend.log` passes 546 tests; `FinalTools.log` passes 51 tests. Python compilation
passes. These exercise local fixture transports only, not live business writes.
The final corrected native/interface/Release evidence is listed above.

The new native execution verifier reads the actual xcresult test tree and
requires every selected target/suite/method to have an exact passing result.
`HardwareKeyboardIPad.xcresult` returned Xcode success with **zero tests**; it is
not acceptance. Its next run really executes and exposes the keyboard defect.
The verifier rejects that original zero-test result and rejects `FinalIPad`
when asked to prove the then-unselected hardware-keyboard test, despite its
1,372 passing results. Nine Tools tests cover those false-green paths, wrong
target identity, malformed evidence, skips/failures and selector validation.

Retained failures distinguish separate causes:

- An over-complex Swift type-check expression and invalid test/fixture syntax
  were corrected without weakening production checks.
- Exact money assertion caught NSDecimalNumber.doubleValue producing
  15.469999999999999 for a $15.47 line. Decimal-to-number conversion now uses
  the canonical decimal string; the exact-cent assertion is unchanged.
- An identifier on DisclosureGroup replaced member edit/remove identifiers
  throughout its accessibility subtree. The identifier was removed from the
  container; each actual control retains its own identity.
- Competing row-owned sheet presentations opened Included Item when group
  quantity was selected. One original request now selects the editor.
- Subsequent iPad evidence reaches the correct editor but reports an invalid
  Save hit point with keyboard focus. `CompositionIPad8.xcresult` passes the
  complete invoice journey after explicit page sizing and keyboard submission.
  Direct Save after touch/backspace entry passes in `TouchInputIPad`. Both
  Command-A plus `typeText` and pure hardware-key replacement failed before the
  keyboard-type correction; a coordinate diagnostic also failed, so the issue
  was not dismissed as only an isHittable assertion. The original direct Save
  assertions pass in `HardwareKeyboardIPad3` after reusing the catalog keyboard.
- `ToolbarDiagnostic.xcresult` proves that expanding bundle members also opened
  the unrelated Create Item disclosure in the same composite List row. The
  scoped disclosure style uses its own plain button and explicit expanded
  value. `ToolbarDiagnostic2.xcresult` passes the independent-disclosure checks
  before reaching its separate Save failure. `TouchInputIPad` then passes the
  full estimate journey with the disclosure independence assertions retained.
  The temporary coordinate diagnostic is not a CI substitute.
- The initial equipment test expected serials in the intentionally concise
  customer label. It now checks that exact label, all member QBO descriptions,
  and lossless saved serials separately; the persistence assertion is retained.

## Required continuation, not waived by this checkpoint

1. Verify the newly published source and 37-journey workflow's exact-head hosted
   checks. The previous `5d16fb8` Native/Backend runs pass but do not qualify
   these later changes. Local verification does not waive hosted acceptance.
2. Extend milestone/progress billing to allocate bundle member charges exactly.
   Its older flat-line quantity calculation does not provide bundle support.
   Intuit explicitly does not expose native QBO progress invoicing through the
   API; GunnAire milestone invoices must not claim to be that provider feature.
3. Complete imported invoice/estimate bundle snapshots and editable native
   imported-document workflows; read/publication support alone is insufficient.
4. Qualify signed iPad/Mac CloudKit delivery and mixed-version client protection.
   Older clients that do not understand bundle JSON must not edit and erase it.
   SQLite round trips do not establish CloudKit or physical-device acceptance.
5. Complete authorized concrete QBO sandbox acceptance, category administration,
   all remaining Google/vendor/access/release features, the ten-competitor
   capability audit, and physical iPad-to-iPhone Handoff/Tap to Pay acceptance.

## Primary references

Revalidated in Safari; no provider operation was executed.

- [Intuit Item and category API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/item)
- [Intuit bundle workflow](https://developer.intuit.com/app/developer/qbo/docs/workflows/manage-inventory/item-bundles-using-groups)
- [Intuit Invoice API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/invoice)
- [Apple disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)
- [Apple numbers-and-punctuation keyboard](https://developer.apple.com/documentation/uikit/uikeyboardtype/numbersandpunctuation)
