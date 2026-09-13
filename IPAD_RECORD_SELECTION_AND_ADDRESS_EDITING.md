# iPad record selection and address editing

## Exact failure evidence

The completed hosted run `34178309515`, head `6a0a38e`, reports 1,300 passed
tests and two failed UI journeys. Its artifact `10038547871` (`iPad-native-1`)
was downloaded read-only and verified against GitHub's length and SHA-256:

- 210,346,181 bytes
- `206261fb1c8b3e1708768fbb21654390067c86627ee60828e621c9c9ba7f9155`

The existing-link recording shows the customer switch still off after its
single synthesized tap at (965.66, 450.5) in the 1032-by-1376 point window.
The point falls inside the visible switch, not outside its row. The recording
does not establish whether event delivery or view handling lost the change.

The tax-address recording remains empty before, during and after typing
`Cancelled address`. Its synthesized field tap is (516, 679), inside the
recorded text-field frame `{{266, 668}, {500, 22}}`. The retained post-input
accessibility snapshot reports the field enabled, `hasKeyboardFocus: false`,
and the unchanged `Street address` placeholder. No keyboard or caret appears
in the inspected frames. This is not the earlier partial-typing race documented
in `TAX_ADDRESS_UI_SYNCHRONIZATION.md`, and a longer value wait alone is not a
proven correction. The underlying reason focus was not acquired remains open.

Both unchanged journeys pass three local repetitions each (six total, no
failures). That does not disprove the hosted failures. No runner or live job
was restarted to obtain the baseline.

## Reproduced shortcut focus defect

The first UI candidate passes the three existing-link journeys and 25 focused
logic tests, but still fails address entry. Its local recording is stronger
evidence than the original log: at 25.998 seconds it visibly contains the full
`Cancelled address` and keyboard; by 27.815 seconds the field has returned to
its placeholder and the keyboard is gone. Keyboard existence alone is therefore
not sufficient evidence of a durable edit. This failed candidate is retained
as `ImprovedInteractionFocused.xcresult` and `LocalFocusedFailure/`.

Inspection found the iPad shortcut bridge calling `becomeFirstResponder()` on
every representable update, with an asynchronous callback that does not recheck
current focus. `ShortcutFocusReproduction.xcresult` proves this defect using the
production bridge before its correction: both a focused UITextField and a focused
UITextView lose first-responder ownership to the bridge after an update (two
failed tests, four issues). The control case, activating after editing ends,
passes. Only type visibility was changed to enable these direct tests; the
bridge's original runtime logic was unchanged for the reproduction.

The corrected bridge activates only in a key window without another view's
first responder or a presented controller. Its bounded fallback callback
rechecks those conditions at execution time. It never resigns an editor on the
user's behalf. Six direct regressions cover single-line/multiline editing,
new focus acquired after an activation request, modal ownership and reactivation
after editing. A controlled responder initially refuses activation to prove that
the actual queued callback both retries once when available and refuses to evict
an editor focused in the interim; it does not merely test synchronous activation.
The existing Command-7 UI journey now requires a single press,
without its old second-press fallback.

Apple's [first-responder documentation](https://developer.apple.com/documentation/uikit/uiresponder/becomefirstresponder())
confirms that becoming first responder asks the prior owner to resign. The
direct tests establish the app defect; the final UI runs must separately
qualify the actual address workflow. They do not retroactively prove this is
the sole cause of every prior hosted switch/input failure.

## User-facing changes

The records page now uses an accessible, full-row selection button and a
checkmark, rather than requiring a small switch target for a temporary batch
choice. The entire row is at least 44 points tall. A shape and the Selected
accessibility trait/value communicate state without depending on color.
The same selection set, 25-record cap, busy protection, explicit review and
confirmation, cancellation and original-request recovery remain in place.
Selecting a row still does not alter a QuickBooks customer or invoice.

Address fields retain their labels after input. Tapping the label or blank
area focuses the associated native text field; native text selection keeps its
own gesture. Each field has a distinct SwiftUI focus binding, Next advances in
address order, and Done dismisses the keyboard without saving. Hidden sale
fields cannot retain focus when the same-location option is enabled. No field
is automatically focused on opening a review, and no address or jurisdiction
is guessed. Required address validation, draft scope and sold prices are unchanged.

The interface choices follow Apple's current guidance, checked in Safari:
[text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields),
[toggles](https://developer.apple.com/design/human-interface-guidelines/toggles),
and [FocusState](https://developer.apple.com/documentation/swiftui/focusstate).
[XCUIElement.typeText](https://developer.apple.com/documentation/xcuiautomation/xcuielement/typetext(_:))
requires keyboard focus. The tests now explicitly require keyboard presentation
before entering text, retain exact-value assertions, and exercise Next without
tapping each destination field. The three existing-link journeys require
select, deselect, and reselect, with exact selection count and review-button
availability after each individual action. There are no retry-until-success
gestures, replayed address strings, shorter expected values, skipped journeys,
or direct model-state injection to satisfy these checks.

The record/form changes improve usability, and the shortcut correction fixes
a directly reproduced focus-ownership defect. Local validation is detailed below;
hosted and physical-device qualification remain separate.

## Validation

The next candidate (`FocusProtectedIPad.xcresult`) passes all 1,276 logic tests,
including the five focus tests, and six of seven selected UI journeys: the three
existing-link paths, Invoice opening, simple Mail, and one-press Command-7.
The address journey still fails. Its recording at 27 seconds shows the full
cancelled address and keyboard; by 29.393 seconds both the text and keyboard
are gone. The bridge fix is therefore not sufficient to resolve the editor reset.

The review sheet was owned by a row inside the underlying lazy billing list.
The next correction moves the captured review session and sheet presentation
to the stable billing workspace. Keyboard-driven changes to the scrolling list
must not own the editor's identity. A unique request captures its initial values;
save checks the active request, current customer/site scope, taxable lines and
document-write state. Cancel remains temporary, and scope changes close the
review. `WorkspaceOwnedTaxReview.xcresult` passes both the complete address
journey (105.608 seconds) and Invoice opening (10.368 seconds), with no failures
or skips. Its retained screenshot was inspected: all four entered fields retain
their persistent labels and complete values, the same-location choice is on,
the keyboard is dismissed, and no account-email footer is visible. This removes
the row-owned presentation hazard; it does not retroactively prove the cause of
each older hosted failure.

The initial Mac focus run stalled in the new modal-presentation test, whose
unchecked-duration continuation awaited a UIKit completion callback. A retained
process sample shows an idle event loop awaiting the test. The exact xcodebuild
process was interrupted after this diagnosis; it exited 73 and reported an
incomplete result bundle. Its command log and sample remain evidence of failure,
not a pass. The fixture now checks actual presentation ownership after a main-queue
turn and dismisses without awaiting an animation completion callback. None of its
focus/ownership assertions or tests was removed. `BoundedFocusMac.xcresult`
passes all 1,276 logic tests. The final strengthened delayed-retry tests then
pass with all **1,277** logic tests in `FinalInteractionMac.xcresult`, no failures
or skips, using Xcode 26.6 and arm64 Mac Catalyst on macOS 26.6.2. The corresponding
iPad run passes 1,277 logic tests and eight of nine UI journeys. Its address
failure is different: every entered value and keyboard dismissal passes, then
the test loses its CollectionView query after scrolling. The query selected the
form by an offscreen street-field child that the lazy form no longer exposes.
The retained recording at 66.865 seconds and accessibility snapshot show the
same open form, retained state/ZIP values and visible sale-location switch.
`FinalInteractionTaxFailure/` retains this evidence; the run is not a full pass.

The form now has a stable `BillingTaxAddressForm` identifier, and the scrolling
helper selects the form itself. The single toggle tap, complete-value checks,
cancel/save/price/reopen assertions and scrolling bounds remain unchanged.
`StableFormIPadRepeated.xcresult` repeats the full logic target and entire address
journey three times and passes: **3,831 logic executions** (1,277 per run), and
**three complete address journeys**, with no failures or skips. The address runs
take 104.883, 105.120 and 103.971 seconds. Repetition is unconditional, not
retry-until-success. Each UI run launches the fixture app anew; no text or tap
is replayed to repair a missed interaction. `StableFormMac.xcresult` reruns
the complete Mac logic target after this accessibility-only app change and
passes all 1,277 tests with no failures or skips. The selected-record screenshot
was also inspected: a clear checkmark, one selected record, enabled review action,
native Back navigation and no account-email footer; there is no raw API content.

The final universal unsigned Mac Release build passes in
`StableFormMacRelease.xcresult`; `lipo -verify_arch arm64 x86_64` confirms both
supported Mac architectures. The final address screenshot was inspected again:
complete labeled fields, the confirmed sale-location switch, an enabled save
action, no keyboard obstruction, and no account-email footer.

Separately, published head `d804dd6` completes both hosted jobs successfully:
[native iPad and Mac](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34180882997),
[backend Python 3.13 and 3.14](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34180882993).
Those green results precede this candidate and do not qualify its changes.

The eight adjacent UI journeys passed before the final change that adds only a
form accessibility identifier and updates its test locator. They cover all three
existing-link flows, Invoice opening, simple Mail, single-press Command-7, and
management invoice/estimate cancellation and offline saving. They are not counted
as part of the final repeated-address bundle. All six new focus tests run in the
complete logic target on both platforms without changing workflow selectors.

Local qualification is complete for this checkpoint. Fresh exact-head hosted CI,
signed physical-device input/keyboard acceptance, and the full-suite gates below
remain required. No claim of universal or production readiness follows from these
fixture results.

## Frozen source

The app, logic-test and UI-test directories in the review clone and original
iCloud project compare byte-for-byte equal. The build mirror points to those
original directories and retains the unchanged shared scheme and project.
No deployment target, entitlement, schema, signing or configuration file changes.

| File | SHA-256 |
| --- | --- |
| `BillingDocumentsView.swift` | `309ff25817c6ea0e8c42f731efac5fe34d958b90e4badab5fc76228efbc02062` |
| `BillingTaxAddressReview.swift` | `16800354644766b648fe9d378ff855ed9eafc46d620a0d7e45166dec9ded6113` |
| `ContentView.swift` | `3ab29b1864a9ba3d8a677b77d96c3875ffebdeefd8e55024910819655c26c732` |
| `QuickBooksLinkReviewView.swift` | `c038d2091c326ddd9d8ff5d513505a60abca7447896fe74e91ac1c67a087433b` |
| `IPadKeyboardFocusTests.swift` | `26c3d28a946bc6a32a1ab35170cc11f8012f5b1c8f3f5f897d3de65ac32db0b3` |
| `GunnAire_OpsUITests.swift` | `9b74176a7ba8e0a5b232813dea929b7174e42c1da102d182096908248dccac37` |

Final universal Mac executable SHA-256:
`ccfd45e8f3d64b320796030f1e94bf54a7b03ccaa12a421ef5092a57b1a06023`.

Evidence root:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/iPad Interaction Diagnosis.vPVwuM/`.
It retains the digest-verified ZIP, original result bundle, failure recordings,
synthesized events, accessibility snapshots and extracted frames, plus
`BaselineRepeated.xcresult` and its command log.

The full business-suite objective remains open: comprehensive QBO lifecycle
reconciliation and native change-history consumption, independent staff CloudKit
sharing, provider qualification, physical iPad/Mac/iPhone handoffs and Tap to Pay,
vendor onboarding and release acceptance are not established by these UI checks.
No merge, deployment, entitlement/signing change, physical installation or live
provider write is part of this checkpoint.
