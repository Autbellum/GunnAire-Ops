# Saved billing evidence before complete staff synchronization

Locally qualified checkpoint, September 9, 2026. Full independent-account CloudKit operation and the
complete business-suite goal remain unfinished. This checkpoint closes a shared
saved-document validation gap that must be resolved before full staff projection.

## Reproduced gap

Published parent `223f1b4` uses the historical catalog decoder in QuickBooks
publication and does not validate catalog snapshots inside the complete staff
relationship graph. Reproduction1 actually executes two cases: a version-999
envelope passes publication totals validation, and an unknown financial field
passes the staff graph. Both expected rejection assertions fail. The original
result and logs remain retained, rather than being represented as a passing gate.

## Shared correction

`CatalogSnapshotPayload` accepts the existing legacy line array and version-one
document envelope, including original discount and tax-address evidence. It
rejects unknown/duplicate keys (including escaped-equivalent duplicates), unknown
versions, malformed types, explicit null defaulted quantities/prices, duplicate
top-level item identities, conflicting bundle-row identities, recursive bundles,
nonfinite numbers, NUL text and bounded-resource violations. Optional historical
values and documented absent legacy defaults remain supported. The complete
original JSON is never rewritten or replaced with current catalog values.

The existing duplicate-key-aware parser retains its default field-form limits.
Only the catalog caller requests the larger bounded node allowance needed for
750 detailed sales rows; the one-MiB byte bound and depth limit stay in place.
Over-limit documents reject as a whole, never truncate into a partial invoice.

The strict boundary is used by catalog restoration, bundle scope checks,
QuickBooks line construction and prerequisite workflow checks, staged invoice
allocation, estimate approval and invoice payment/PDF readiness. Read-only
historical display remains lossless; a plain review message prevents unsafe
changes without printing payloads or erasing the original document. No customer,
catalog, invoice, payment or provider operation is issued by validation.

The full staff graph additionally validates stored quantity/price/cost, original
adjustment and discount evidence, bundle/assembly semantics and original catalog
and customer-equipment lineage. Historical names, prices, serial numbers and
approvers need not equal current catalog/profile values. Missing historical
parents require resolution, not invented records or silently dropped links.
Imported approvers and AppUser rows remain data, never current membership grants.

## Qualification

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Catalog Snapshot Integrity.rrJSJX`.

- Reproduction1: two actual failing rejection cases against the parent source.
- Focused1: test compilation fails on missing inner `try` in Swift Testing
  macros. The assertions are retained; the test setup is corrected.
- Focused2: 123 cases pass and one fails because the strict reader changes the
  existing bundle-restoration error category. That boundary now preserves its
  established CatalogBundleError contract; the rejection assertion is unchanged.
- Focused3: all 125 actual cases pass across six selected suites, including the
  added exact-tax-scope and stored-net-subtotal staff checks.
- Tools1: all 74 cases pass; no workflow edit or coverage removal is included.
- MacFull1: 1,842 actual cases pass, one fails with the same error-category
  compatibility issue in staged invoice allocation. That full run is not green.
- IPadFocused1: all 14 new logic cases pass; the UI journey fails because the job
  billing layout shows the review message and disables Update but omits the
  replacement control present in the standalone composer. The actual retained
  accessibility tree distinguishes this genuine layout gap from a test lookup
  assumption. Both layouts must offer the same deliberate recovery action.
- MacFull2: all 1,843 actual cases pass, with seven verified selectors.
- IPadFocused2: 14 logic cases and the ordinary job-billing review journey pass.
- IPadFull1: all 1,853 actual cases pass, with 17 verified selectors, including
  ten ordinary iPad journeys. MacRelease2 and DeviceRelease2 unsigned builds
  pass, with both Mac architectures verified. These qualify the intermediate
  correction, not the final UI refinement below.
- Visual review of the passing iPad frame still finds a misleading $0 draft
  total and QuickBooks-pending cue beside an unreadable original $189 invoice.
  The shared recovery view now presents the stored total, hides draft line-item
  controls and sync cues until explicit replacement, and keeps both document
  actions disabled. The replacement action changes editor state only and
  explains that the saved original remains intact until saving.
- The expanded iPad journey verifies the stored total, absence of misleading
  controls/cues, explicit replacement, leaving without saving and reopening the
  original invoice with the same review and saved total.
- Tools2: all 74 cases pass in 4.597 seconds on the final candidate.

OriginalPreflight3 freezes the final recovery refinement across 16 scoped paths,
protects 378 unrelated original changes and verifies 386 other tracked source
files match. The owner branch, HEAD and index are protected. Focused4 verifies
125 cases and six selectors; IPadFocused3 verifies 15 cases and two selectors.
The latter includes the expanded leave-without-saving recovery journey. Its
retained frame was visually inspected: the saved $189 total and one review action
are visible, the false $0/pending cue is absent, Update remains disabled, and no
raw JSON or account-email footer is displayed.

Final MacFull3 verifies 1,843 actual cases and seven selectors with zero failures
or skips. Tools2 passes all 74 tests. DeviceRelease3 and MacRelease3 unsigned
Release builds pass and lipo verifies arm64 iOS and arm64/x86_64 Mac Catalyst.
SHA-256:

- iOS: `e6e450deb6536ea7e77ad0365b6c97105fee7ebf11dc2945977e60c77e0b7016`
- Mac: `a45401a9f3e3aefdfd875858233f2a900a7cecef90ea2ac30248f69a464fbbad`

Existing native QBO default-argument and Optional.map actor-isolation diagnostics
remain uncorrected; successful builds are not represented as warning-free.
Final IPadFull2 verifies 1,853 actual cases and 17 selectors with zero failures or
skips: the complete 1,843-case logic target and ten iPad UI journeys. These cover
the new recovery, Invoice opening, simple Mail, assigned-technician item creation,
three bundle editing/keyboard paths, tax-address return, and both staff CloudKit
setup/recovery journeys. Backend1 passes all 852 tests in 129.280 seconds using
isolated fixtures; no backend implementation or provider contract changed here.
Mac UI acceptance remains distinct from the complete Mac logic target and
unsigned Release build.

Commands are retained in `qualify_catalog_snapshots.sh` beside the checkpoint
helper at `/tmp/gunnaire-workflow-validation.NYZ8uS`. Xcode 26.6 uses the existing
`GunnAire Ops` shared scheme, arm64 Mac Catalyst and the existing 13-inch M5 iPad /
iOS 26.2 simulator `BEFCCCDA-689B-4825-86AE-09F29ADD4FA7`, with
`CODE_SIGNING_ALLOWED=NO`. Every qualified test result is checked against the
actual xcresult test identities, not just a successful xcodebuild exit.

The final full-run Inbox and ordinary edited-bundle composer frames were also
visually inspected. They retain native message/line-item controls without raw
payloads or account-email footers. This is targeted visual verification, not
whole-suite accessibility acceptance.

OriginalCopyBack1 verifies all 16 scoped files byte-equal in the owner project,
all 378 unrelated changes preserved, and the owner branch, HEAD and index
unchanged. Only the isolated review checkout is staged and committed.
At 20:53 UTC, published parent `223f1b4` remains the head of open PR18. Its backend
run 34398474919 and Mac job pass; both iPad jobs in native run 34398474947 remain
active. This new source is not pushed over that live run and has no exact-head
hosted CI result yet. No predecessor is cancelled or restarted.

## Subsequent hosted Mail failure

Subsequent hosted evidence, 21:07 UTC: parent native run 34398474947 has now
finished. Mac and iPad group 2 pass; group 1 fails. Its actual xcresult contains
1,862 passes and one failure out of 1,863 cases. The failure is
`testMailAttachmentPreviewAndForwardRetainTheOriginalFile`, at the expected
preview-content assertion (UITests line 358), not invoice recovery.

The exact group-1 artifact `10124571328` was downloaded without forwarding
credentials, verified against GitHub's byte length and SHA-256
`ccbb8953595b79908ccc5d9fd73ac50483fd202d7e1407ba691623b1c1e84391`, and safely
extracted under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Mail Preview CI.tZN0aD`.
The failure's actual accessibility tree has the Equipment title and Done
control but no expected text. Its recorded Quick Look sheet is visibly blank.
That is a real observed preview failure, not merely an accessibility-query
assumption. LocalReproduction1 runs the unchanged exact journey on checkpoint
`929993f` and verifies one actual passing case; that local pass does not prove
the intermittent hosted failure fixed. No assertion, test or coverage is
removed. Root cause and reliable preview recovery remain open, and this PR
must not be represented as all green.

## Full goal remains intact

This is not complete nested validation for all business domains, a role-safe
full-domain wire contract, schema-separated server-ledger migration, isolated
staff-store activation, durable technician command reconciliation or file-byte
delivery. Those paths, signed independent-account CloudKit acceptance, complete
QBO/provider/vendor acceptance, iPad-to-iPhone payment/Handoff, competitor-feature
coverage and wider iPad/Mac accessibility/usability remain required. There is no
production deployment, signing/schema promotion, physical install, main merge,
accounting mutation or broadening of the private owner-store gate.
