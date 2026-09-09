# iPad editor reachability and original-save handoff

September 9, 2026. Native candidate; not full-suite or production acceptance.

## Follow-up: intermittent fractional hardware entry

The subsequent `Staff Discriminators.3fSCzM/IPadFull1.xcresult` broad run failed
the strengthened inventory assertion: after individual hardware `6`, `.`, `5`
events, the field reported `6`, not `6.5`. The recording's final rendered field
also reads `6`, so this is not merely a stale accessibility assertion. No Done
or Save action had occurred between those events. The prior passing run below
does not prove this intermittent input problem resolved.

The follow-up candidate replaces the optional-number-bound quantity field with
a native text-bound local draft. Numeric interpretation no longer writes back
into the field between keystrokes. Both create and edit explicitly validate the
draft before applying it to the existing inventory setup. Blank remains nil
(unfinished offline setup), not zero; invalid nonblank text cannot silently save
the prior quantity. Account scope, opening date and account references remain
unchanged, as do provider contracts and the complete-setup publication gate.
Cancel still discards only the local editor state. The original unmodified
hardware/cancel/reopen journey passes in `QuantityFocused1.xcresult`, alongside
19 inventory logic cases (20 actual cases, zero failures/skips; both requested
selectors verified). This supports the draft-state correction but is not by
itself proof that an intermittent defect is eliminated.

The expanded journey also rejects invalid nonblank quantity in both creation
and editing, restores valid input, stages a fractional edit with the keyboard
active, and reopens the exact quantity/date and unrounded sales price. It retains
the original `6.5` hardware/Done checks and Cancel → original `4.25` assertions.
Name, SKU, sales price, description, purchase cost and purchase description/notes
now have persistent native labels in both catalog forms. No input action is
retried to hide a failure, and neither test selectors nor pass criteria are
weakened. Complete current-source and fresh-process repeated qualification are
recorded below.

`QuantityRepeated1.xcresult` reports one passing test with three passing
repetitions. However, detailed activities/attachments show the original journey,
not the added invalid-input/save assertions. Its built test binary contains the
new strings and the rendered app has the new labels, but the runner discrepancy
is not assumed resolved. These repetitions are not credited as expanded test
coverage. `IPadFull2` does execute the new invalid-input actions, Stage Changes,
and named saved-fractional attachment. A further fresh-process repetition run
will require all three passing Repetition nodes and three new saved-fractional
attachments. No runner/data reset or live-job cancellation is used.

The local validation helper also required two corrections unrelated to app
behavior: Bash's empty-array expansion under nounset stopped `MacFull2` before
building, and editing the helper during the first repeat run broke its later
shell parsing. `MacFull3` starts from the corrected helper; the completed repeat
result was inspected and verified separately without restarting that live run.
Running scripts, as well as compiled sources, are now left unchanged through
completion. Original failed results and the scope limits above remain retained.

Current-source qualification in `Staff Discriminators.3fSCzM`:

- `MacFull3.xcresult`: 1,768 actual cases, zero failures/skips, complete logic
  target verified. Unsigned universal Mac Release and arm64 iOS Release pass,
  with architecture checks; exact hashes are in `STAFF_DISCRIMINATOR_VALIDATION.md`.
- `IPadFull2.xcresult`: 1,779 actual cases, zero failures/skips, all 12 requested
  selectors verified (complete logic plus 11 UI journeys). The added inventory
  actions and saved-fractional attachment are present in its actual activities.
  Invoice opening, simple Inbox, all three bundle editors, taxable catalog
  creation, pricebook review and staff-access recovery also pass.
- All 74 Tools tests and both workflow lint checks pass. No workflow change.
- Two final-run frames in `FinalInventory` and `FinalEstimate` were inspected:
  saved quantity `6.5`, unchanged `125.375` price and original opening date,
  persistent catalog labels, and original-customer estimate confirmation. No
  account-email footer appears. Existing dense accounting help, multiline-label
  layout/placeholder polish, whole-app/Mac UI and accessibility remain review
  work, not certified by these two dark-mode frames.

Existing document-workflow actor warnings remain; repeated-test results also
record an unattributed non-finite-frame runtime warning. Neither is suppressed
or represented as resolved.

`QuantityFreshProcesses1.xcresult` completed without cancellation/restart at
16:50 UTC on September 9. All three independent-app-launch repetitions passed,
and each retained the new named saved-fractional attachment, proving execution
of the expanded body rather than assuming it from a stale runner. Every final
frame was inspected and shows saved `6.5`, full `125.375` price, original date
and persistent labels without an account-email footer. Repetition 2 took
3,997.205 seconds during repeated XCTest animation waits; repetitions 1 and 3
took 116.123 and 114.029 seconds. This resolves the repeat-coverage gate, not the
remaining runtime-warning, general latency, accessibility or whole-app gates.

## Exact observed failures

Native run `34354492697`, published head `33413e4`, failed two iPad group-1
journeys. Its artifact `iPad-0-native-1` was downloaded without forwarding GitHub
credentials to storage and verified against GitHub's length (355,918,680 bytes)
and SHA-256 `b9804906a5392de4e5ff588608f84fa866a2da3ca163e006430b10575beccf75`.
Original logs, xcresult, recordings, accessibility snapshots and extracted frames
are retained in the local release evidence directory `iPad Editor Recovery.cgUtsm`.

- Inventory create/reopen: the last keyboard Done control is visibly rendered,
  but XCTest records its frame as `{{inf, inf}, {0, 0}}`. Reading `isHittable`
  raises an immediate framework failure during the existing readiness wait.
  This is evidence of invalid accessibility geometry, not a corrupted item or
  proof that a normal touch could not dismiss the keyboard.
- Estimate bundle editing: the recorded form has height 650 and bottom edge
  1008, while Create spans y=1004.5...1069. Its content is clipped below the
  sheet, yet XCTest reports it hittable and the attempted tap does not reach
  the saved-customer confirmation. The final recording and hierarchy still
  show the edited draft, not a saved estimate. No accounting error is shown.

An unchanged-source local run passes both original journeys on the M5 13-inch
iPad/iOS 26.2 simulator. `UnchangedIPad.xcresult` and its authoritative execution
tree verify two passed cases, zero failures/skips. This does not invalidate the
hosted evidence or prove an intermittent defect fixed.

## Candidate changes

Standalone invoice and estimate composers keep their sole Create action in the
native confirmation toolbar, independent of form scrolling and nested keyboard
editing. Existing validation, current-role checks, original-document guard and
the same create/save function remain. The old inline action remains for existing
job/document workspaces; new composers do not offer a duplicate Create button.
When an original document is retained, the confirmation list gets that document's
identity so it opens as a reading destination rather than retaining the long
form's scroll offset. Failed-save recovery still refers to the original draft.

Inventory opening quantity and date retain visible labels after data entry,
with explicit accessibility names and date-format help. Number/date bindings,
precision, focus/Next/Done behavior, account scope and provider payloads are
unchanged. The existing bounded UI readiness helper waits for finite, nonzero
geometry before asking XCTest for hittability; it still requires an actual
hittable element and fails at the same timeout. It does not retry a user action.

Existing bundle journeys now require exactly one Create action fully inside the
toolbar, visible original-customer confirmation, exact saved bundle/member values
and natural return to Management. Inventory retains all original assertions and
adds a physical-keyboard edit/cancel/reopen check for the unchanged saved quantity,
date and full price precision. No failed journey or assertion is dropped.

Apple's [keyboard guidance](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards)
informs the retained standard keyboard and visible primary action. Actual
implemented interactions, not mockups, must qualify the candidate.

## Qualification

Evidence root: `/Users/gunnaire/Downloads/GunnAire Ops Releases/iPad Editor Recovery.cgUtsm`.

- `MacFull1.xcresult`: 1,755 actual cases passed, zero failures/skips, with the
  complete logic target verified against the result's executed-test tree. The
  subsequent correction affects only the UI-test keyboard driver, not app or
  logic-test source.
- `FocusedIPad1.xcresult`: all three invoice/estimate bundle journeys passed. The
  added inventory keyboard check initially failed because XCTest rejects the
  multi-character `typeKey("6.5")` event. That test-driver mistake was corrected
  to individual key events; the failed result remains retained, not relabeled
  as an app failure or silently discarded.
- `IPadFull1.xcresult`: 1,767 actual cases passed, zero failures/skips, on the
  13-inch M5 iPad/iOS 26.2 simulator (23C54), Xcode 26.6 (17F113). The result tree
  verifies all 13 selectors: complete logic plus all 12 requested UI journeys.
  These include exact inventory/hardware edit/cancel/reopen, all three bundle
  editors, invoice opening, simple Inbox, offline original invoice/estimate
  creation, unsaved-draft cancellation, catalog approval/precision/taxability,
  and cancellation after QuickBooks reconnection. Fixtures do not call providers.
- `MacRelease1.log` and `DeviceRelease1.log`: unsigned Release builds passed;
  binary architecture checks verified Mac arm64 + x86_64 and iOS arm64.
  Mac SHA-256: `9036f48b763337f349dfdfc868d74ac74a01e9d4a45a694e8699a3eea47b98e3`.
  iOS SHA-256: `7396fdef7d6b1955ca116b9e50c99b97f6991497a5cae0ec7fd8284927c3f4f8`.
- All 74 Tools tests and both workflow actionlint checks passed. No workflow,
  test selection, timeout, or failure gate is weakened by this candidate.
- Three final-run dark-mode iPad screenshots in `FinalEstimate` and
  `FinalInventory` were visually inspected: the full toolbar Create action,
  original-customer confirmation at the top, exact saved bundle/member values,
  and persistent opening-quantity/date labels. No account-email footer appears.
  This is not light-mode, VoiceOver, extreme Dynamic Type, or whole-app/Mac UI
  acceptance. Other catalog name/SKU/price inputs still need persistent-label
  review; this scoped correction does not imply the entire editor is finished.

Existing actor-isolation warnings in `QuickBooksDocumentNativeWorkflow.swift`
and `QuickBooksDocumentUpload.swift`, plus the Mac Metal-toolchain search-path
warning, remain recorded in the release logs. They are not suppressed.

`OriginalPreflight1.json` freezes the three changed Swift files and scopes the
five-file copy-back, protecting 367 unrelated changes, 381 other matching tracked
sources and the original branch/HEAD/index. Copy-back verification confirms all
five files byte-equal, all 367 unrelated changes preserved, and unchanged original
branch, HEAD and index. The qualified change is retained in the local review branch.
Publication waits for the preceding hosted native run to finish. The published
`f8cfc92` passes Backend Python 3.13/3.14, hosted Mac, and both hosted
simulator-preparation steps; its two iPad jobs are still running in native run
`34362120065`. That source does not contain this editor candidate. Do not cancel
or supersede the live run.

No business-model/schema, signing, entitlement, provider, deployment, live
accounting/payment/customer action, physical installation or main merge changes.
Full independent-account CloudKit operation, provider/vendor and device
acceptance, and whole-app iPad/Mac accessibility remain required by the active goal.
