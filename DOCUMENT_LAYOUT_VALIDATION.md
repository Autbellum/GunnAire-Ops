# Business-document text pagination

September 9, 2026. Candidate based on review checkpoint `a6a5d45`.

## Reproduced failure

Evidence root: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Document Layout.Rk2i6j`.
`Reproduction1` ran the actual native exporter on arm64 Mac Catalyst with
Xcode 26.6 (17F113). All three new layout tests failed, with five issues.
The original 120-line service answer produced three pages: lines 32-36 extended
into the footer/off-page and lines 37-120 were absent from PDF extraction.
A 48-part original question lost parts 20-48. The empty repair report printed
Equipment and Service Notes headings without values.

The retained PDF attachments and rendered `ClippedService-2.png` confirm the
service note runs through the footer and is visibly cut off. These are genuine
output defects, not test discovery, simulator startup or signing failures.
The former renderer moved an oversized row to a fresh page but still drew its
entire height there. It drew headings before checking for populated rows.

## Candidate correction

The shared exporter uses a Core Text backing store per column and advances
only through `CTFrameGetVisibleStringRange`. Both original question labels and
answers can continue independently; an answer is not repeated when its label
is longer. Ordinary rows and fitting account-statement groups stay together.
Continuation pages retain section context, body margins and a separate footer.
Blank sections consume no heading or spacing. The existing readiness, lineage,
financial and original-response validation remains in force.

An impossible layout fails explicitly rather than dropping text or looping.
PDF bytes are written atomically only after successful rendering, preserving
an existing PDF if layout fails. Source customer/job/answer/accounting records
are never rewritten by pagination.

Apple's installed SDK documentation for CTFrameGetVisibleStringRange explicitly
defines its use for chaining visible character ranges; CTFrameDraw requires
context-state isolation. The implementation preserves that UTF-16 range and
saves/restores the graphics state around the UIKit/Core Text coordinate flip.

## Qualification status

`Fixed1` passes all three original regressions. All eleven rendered pages of
those three actual PDFs were inspected: service evidence continues through
line 120, original questions through part 48, no content crosses the footer,
and empty headings are absent while readiness and job references remain.

`Fixed2` passes six of seven expanded cases. Its billing test incorrectly used
the invoice's internal `notes` rather than customer-facing `completionNotes`.
The actual invoice export intentionally omits the internal field. The fixture
now uses the customer completion field and additionally requires the internal
note to remain absent from the PDF and unchanged in its record. No production
export rule or assertion about preservation/visibility was removed.

`Fixed3` passes all seven expanded cases, including exact Unicode/UTF-16
preservation, bounded progress, explicit no-fit failure without consumption,
and a one-page short form. All nine rendered pages of the final-source invoice,
estimate and short form were inspected: all 95 work lines continue cleanly,
amounts follow the notes and the internal invoice note remains absent.
`MacFull1` passes 1,798 actual logic cases and eight required selectors;
`IPadFull1` passes 1,801 cases (complete logic plus all three selected UI
journeys) and eleven required selectors, zero failures/skips. Unsigned Release
and architecture checks pass for arm64 iOS (`DeviceRelease1`, binary SHA-256
`8a04fbefaf1266a8dd15df8be5c5fa8cecb321612f0d70411ca038b475556582`)
and universal Mac (`MacRelease1`,
`863ee3d132046bf6ebfad3bd3995182e759e859cd1b260a7812f2600b4748475`).

Subsequent review identified an inconsistent first-frame reservation at a page
boundary. `BoundaryReproduction1` preserves seven passes and one genuine new
failure: a completion block with a 20-line form title leaves an orphan Responses
heading before its short answer moves to the next page. The candidate now uses
the same 30-point safe frame minimum to reserve a heading and the last row of a
kept-together group. Earlier passes do not qualify this later change.

`Fixed4` now passes all eight layout cases. Final-source `MacFull2` verifies
1,799 actual logic cases and all eight required target/suite/legacy selectors;
`IPadFull2` verifies 1,802 cases, including the complete logic target and the
invoice-opening, customer-statement generation/return and saved-form-history
UI journeys. All eleven iPad selectors are present, with zero failures/skips.
The iPad destination remains the 13-inch M5 on iOS 26.2; Mac is arm64 Catalyst.

All 22 rendered pages of the seven `Fixed4` PDF fixtures were visually inspected,
plus both pages of the actual iPad boundary fixture. The response heading and
answer now stay together; original lines, amount rows, margins and footer remain
readable. No empty trailing page or account-email footer appears in these cases.
These are fixture-output checks, not full dynamic-type/accessibility or arbitrary
document-content qualification.

Final unsigned `DeviceRelease2` passes the iOS arm64 build and architecture
check, binary SHA-256
`e974e578a44559e5bda3d9f16d33b9020dfee766e68aab6192dd4f0d4bc07a8b`.
`MacRelease2` passes universal arm64/x86_64 Release and architecture verification,
binary SHA-256
`3ac66e1420ca3de799d9934a46cb414a8d517a0d5cb1edb30dbe520c09cb6cd9`.
All local runs are terminal. All 74 Tools tests, both unchanged workflows through
actionlint and git diff --check pass. Existing unrelated actor and test-macro
warnings remain; no new document-layout warning was observed. These unsigned
builds do not constitute signing, physical-device installation or release.

`OriginalPreflight3.json` freezes the three final source/test paths and protects
five copy-back paths, 379 unrelated owner changes, 389 other matching tracked
sources, and the original branch, HEAD and index. The copy-back preview passes
those preservation and frozen-source checks without changing the owner checkout.
Final copy-back verifies all five scoped files byte-equal to this qualified
candidate, with all 379 unrelated changes and original branch/HEAD/index preserved.
The review-branch checkpoint is not yet published. Predecessor e7c6c8a has passed
Backend, Mac and iPad group 2; group 1 in native run 34380679032 remains live.
A successor push will not cancel that run. Hosted checks on this exact candidate
are still required after publication; no workflow or credential scope changed.

This is not a whole-suite completion claim. Long page-header/customer text,
arbitrary section-title lengths, photo-caption layout, report-readiness density,
field-form draft recovery and whole-app accessibility remain separate review
items. Mac UI runner signing, signed independent-account CloudKit convergence,
provider/vendor/Tap to Pay/Handoff/device acceptance, full staff projections,
durable commands/files and other completion-matrix gates remain unfinished.
