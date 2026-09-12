# Catalog keyboard navigation and hosted iPad diagnostics

September 8, 2026. This is a native interaction checkpoint, not production
deployment or full-suite acceptance.

## Observed failures

The completed hosted native run `34299083079` at source `3238b77` has two
failed iPad journeys. The Mac job and both Backend jobs passed. The failed
test names and original assertions are retained, not removed from CI:

- `testAdministratorCreatesInventoryOfflineAndReopensExactSetup` cannot reach
  `InventoryOpeningQuantity` at original line 7422. Its recording shows the
  Inventory segment selected, the price keyboard still open, and eight
  application-level swipes failing to move the catalog form to opening stock.
- `testExistingQuickBooksLinkReviewCancelsAfterReconnection` times out reading
  the initial accessibility value `Not selected`, before any selection tap.
  The recording visibly shows zero selected records. The next journey using
  the same selection helper passes. That does not prove a lost tap, an incorrect
  accounting state, or a reconnection defect.

Evidence is retained in
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Hosted Navigation.ymODns`.
Both hosted iPad artifacts were verified against GitHub's exact run, artifact
identity, byte length and SHA-256 before extraction. Downloads never forwarded
the GitHub credential to artifact storage. Original recordings, snapshots,
failure logs and extracted diagnostic frames remain available.

An unchanged-source local reproduction at published head `29d20f8` passes all
1,558 logic tests and both failing UI journeys (1,560 total, zero failures/skips).
This establishes intermittent/environment-sensitive behavior, not a blanket
claim that the hosted failures are fixed.

## Implemented interaction correction

Create and Edit Catalog Item now use one optional focus enumeration across
their text inputs and conditional inventory section. Opening quantity and
opening date participate in the same focus owner as prices and notes. This
replaces the editor's ambiguous shared Boolean for two numeric fields and adds
missing focus ownership to the creation form and inventory section.

Changing item type releases text focus. Both forms provide a standard keyboard
Done action; it dismisses the keyboard without saving, publishing or discarding
the draft. Quantity offers Next to the opening date, and date offers Done.
The forms explicitly support interactive scroll dismissal. Stable form
identifiers let UI tests scroll the visible form rather than the application
window or keyboard. The existing inventory journey now checks keyboard
dismissal during creation and reopening, while preserving the original exact
price `125.375`, quantity `4.25`, and opening date `2026-09-08` assertions.

This follows Apple's guidance on [virtual keyboard layout and relevant controls](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards),
[distinct focus bindings and programmatic dismissal](https://developer.apple.com/documentation/swiftui/focusstate),
and [scroll dismissal](https://developer.apple.com/documentation/swiftui/view/scrolldismisseskeyboard(_:)).
No custom keyboard or additional top-level navigation is introduced.

The existing-link UI test retains exact value, selected trait, review count,
enabled-state and single-tap assertions. Its initial/state wait is bounded at
eight seconds instead of four, allowing the several-second accessibility
snapshot delay visible in the hosted log. Failure now retains a screenshot
and accessibility hierarchy before the original assertion fails. There is no
automatic second tap, success fallback, production link-view change, or weaker
accounting assertion. Hosted verification remains required to establish whether
this resolves the observed timeout.

## Qualification and safety

Final local qualification uses scheme `GunnAire Ops`, Debug, unsigned tests,
serial test execution, and the existing full logic target:

- Focused keyboard/reconnection run: two UI tests pass, no failures or skips.
- Mac Catalyst arm64: 1,558 logic tests pass, no failures or skips.
- iPad Pro 13-inch (M5), iPadOS 26.2 simulator: 1,573 tests pass (1,558 logic
  plus 15 UI), no failures or skips. These include all four existing-link
  recovery journeys, inventory create/reopen, catalog approval/comparison,
  invoice opening, field invoice editing, keyboard-active invoice/estimate
  bundles, and the simple Mail inbox/read/compose/trash journey.
- `verify_native_test_execution.py` confirms actual execution from each
  authoritative xcresult tree: two focused selectors, one Mac logic selector,
  and all 16 requested full iPad selectors. Passing discovery alone is not used.
- All 19 screenshots exported from `FinalIPad.xcresult` are visually reviewed.
  Final inventory create/reopen captures show opening stock and date with the
  keyboard dismissed and the original values preserved. Mail remains a normal
  inbox/message/composer with no raw API response or account-email sidebar
  footer. This is scoped visual evidence, not whole-app accessibility or
  real-device acceptance. Persistent visible labels for populated numeric/date
  catalog fields remain a usability follow-up.
- All 56 Tools tests and both workflow lint checks pass. Workflow selectors
  and permissions are unchanged by this correction.
- Unsigned universal Mac Release succeeds with both arm64 and x86_64 verified.
  Executable SHA-256:
  `534179cbb1ff4eedaeb23a4dda94dcd090e2f794f8e7c95ddcb16e5c5f0e304f`.
- Unsigned iOS device Release succeeds with arm64 verified. Executable SHA-256:
  `94fe75bb1d2b218304c762746cfeaea3653cd7c49f743daa6ed5e83deb4edd88`.

The retained `FinalMac`, `FinalIPad`, `FinalRelease`, and
`FinalIPadDeviceRelease` evidence files identify the exact results and builds.
Existing document actor-isolation and optional Metal-path warnings remain;
they are not suppressed or represented as resolved. Backend source is unchanged
and its full local suite was not rerun for this checkpoint. Published predecessor
`29d20f8` passed both hosted Backend Python jobs; that is not proof for the next
published head. Hosted native CI must still qualify the corrected source,
including the previously intermittent accessibility timeout.

The source and original-project safety preflight covers five scoped paths,
270 unrelated original changes, the unchanged index, and 306 other byte-identical
tracked source files. Final copy-back verifies all five scoped files are
byte-identical, the qualified source hashes are unchanged, and the original
index and all 270 unrelated-file fingerprints are preserved.

No SwiftData field, CloudKit schema, stored invoice price, quantity, provider ID,
account mapping, role policy, API payload, workflow selector, signing setting,
production roster, live accounting record, customer message, payment, installed
physical app, deployment, or main-branch merge is changed by this checkpoint.
Independent-staff CloudKit sharing and signed convergence, approved real
iPad-to-iPhone Tap to Pay, remaining provider workflows, vendor onboarding and
full competitor-suite/real-device acceptance remain open.
