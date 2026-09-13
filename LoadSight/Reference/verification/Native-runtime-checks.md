# Native runtime verification — 2026-09-10

## Reproduce

`python3 Tools/run_native_ui_tests.py --device <dedicated-QA-simulator-UDID>` runs the production app through XCUITest, preserving logs, result bundle, screenshots and a command/device manifest under output/verification/native-ui. It only accepts an available simulator named with the LoadSight QA prefix and erases no simulator data. New documents are test artifacts in that simulator's app container. The scheme includes Native/UITests/LoadSightUITests.swift. Debug builds use ONLY_ACTIVE_ARCH=YES, aligning the app with Swift package debug objects. The runner specifies the host-native simulator architecture.

Current QA devices: iPad Pro 11-inch (M5, 12GB), iOS26.2 C5B99D77-F748-4256-9C89-764F3525E264 and iOS26.5 9066AAB6-E260-46D9-9C41-E337856AFFC0. Both were created for this task. Existing user simulators were not reset.

## Confirmed passing scope

Final run: output/verification/native-ui/20260910T151629793290Z. The actual app creates a native document, opens Overview, navigates to Calculations, switches to envelope and room forms, resets a clean room form without a discard dialog, keeps a dirty draft by dismissing the native popover, discards it explicitly, and calculates a moist-air state from typed70°F/50%RH/14.696psia inputs. The test asserts visible humidity-ratio units and a dismissed keyboard. Screenshots were inspected for workspace, room form and calculated results; final result screenshot is attachments/50C24862-166D-48E3-A6C8-6AD3B9E43940.png. The input numbers are synthetic test data, not project design conditions.

115 model tests passed (output/verification/native-format-tests.log), including two format regressions. Mac build passed (output/verification/native-runtime-mac-build.log). The iOS runtime test includes a fresh app/test-target build. CUA remained unavailable earlier; XCUITest now provides independent native runtime evidence for this limited scope.

## Faults found and corrected

- The test build attempted x86_64 app linking against arm64 Swift package objects. Debug ONLY_ACTIVE_ARCH and a native destination resolve this mismatch; no release architecture is hard-coded.
- iOS26.5 supplied dynamic UTType dyn.ah62d4rv4ge80255bqv30w35ksu with filename extension loadsight. Equality-only format selection serialized regular JSON to a .loadsight URL, despite that extension declaring a package. The writer now recognizes the exact primary type and matching dynamic extension, preserves explicit JSON writing, and rejects unsupported formats. Tests verify actual directory writes, disk round trips, original project fields and regular JSON. Apple documents that package document types conform to [UTType.package](https://developer.apple.com/documentation/SwiftUI/DocumentGroup); the correction keeps the package declaration rather than declaring it a regular data file.
- Fresh field UUIDs made semantically empty room drafts compare unequal. Content-based equality and a loaded/saved baseline now distinguish changed from unchanged forms. New-case resets clear inputs; dirty drafts get a native discard choice.
- Placeholder-only numeric labels disappeared after entry, and the keyboard covered results. Numeric labels now remain visible in air, room-scalar and assembly-path fields. Calculate dismisses numeric focus; iOS Overview instructions refer to the document browser instead of a Mac File menu.

## Still unresolved or unverified

The iOS26.5 simulator still reports NSFileProviderErrorDomain -1005 / DocumentManager1 resolving the created item's bookmark, even after the file is a correct package. Evidence: native-dynamic-package-create.log/.xcresult, plus the directory in the dedicated simulator. The same application creates documents successfully on iOS26.2. This narrows the issue but does not prove the underlying File Provider cause or physical-device behavior. Do not claim iOS26.5 runtime acceptance.

Drawing gestures/calibration, attachment/export interactions, physical-device and Mac interaction acceptance still need runtime checks. Model tests and build success do not prove those workflows. This is not full application or release acceptance.

## Native assembly, room revision and reopen — additional passing scope

Run `output/verification/native-ui/20260910T155438429300Z/` passed `testRoomSaveRevisionAndReopen` on the iOS26.2 QA iPad. The test types every input through the production UI: sourced full-area R10 assembly; a 100ft² opaque wall, no openings explicitly confirmed, indoor70°F and adjacent10°F; room save with600Btuh; revision with author/reason and indoor75°F yielding650Btuh; document close, browser-icon reopen, and visible650Btuh result. These are synthetic fixtures, not design defaults or full-room-load validation. The earlier run 20260910T153313022831Z also captured the app rejecting a save when the no-openings switch had not actually changed.

Source and revision multiline fields now keep explicit accessibility labels after entry. The test helper scrolls controls within usable screen bounds, targets right-aligned input areas and the switch thumb, recognizes combined quantity/value accessibility labels, and opens the document icon instead of the filename rename control. `--only-test LoadSightUITests/LoadSightUITests/testRoomSaveRevisionAndReopen` selects this test. Earlier failed attempts remain diagnostic evidence, not passing acceptance.

Final screenshots were visually inspected: attachments/27A6660F-DA88-4701-8E42-AC8D746553FF.png (600Btuh saved room) and attachments/D5D0B2AD-1AD9-4A8A-9F31-1551560AD967.png (reopened650Btuh with75°F and revision author). The native package is preserved as Verified-room.loadsight. Shared CLI room-review validates that saved package JSON; room-review.json and persistence-check.json confirm one assembly, one stable room, one revision,600/650Btuh before/after, current650Btuh, and author/reason. History disclosure interaction itself is not asserted in this UI test.

Mac build passed after the accessibility change: output/verification/native-room-mac-build.log. The115 model-test baseline remains from the prior pass; no calculation/model implementation changed in this pass. Plugin definitions were unchanged. This extends native workflow evidence without resolving iOS26.5 creation, physical-device acceptance or full application completion.
