# Contextual inventory editing acceptance

Checkpoint date: 2026-09-09. Base: `e8545c2d35393381e1e0b9e98b33a693a80b8a36`.
This is one application-quality checkpoint, not full-suite completion or release approval.

## Observed failure and intended behavior

The retained hosted iPad result for `a0fd766270e2f5100c1f6c87bff13cbeb1120ffa`
contains 1,891 passes and one failure in
`testAdministratorCreatesInventoryOfflineAndReopensExactSetup`. After the
opening date's exact value was verified, the test could not reach the app's
`DoneEditingCatalogItem` control. The recording shows a visible Done accessory
outside the item sheet, above the system keyboard. The failure attachment
contains an unresolved button query. It does not prove the precise UIKit or
SwiftUI cause, nor that every manual tap fails. Metadata/geometry timing and
the separate accessory presentation remain possible causes.

On the unchanged `e8545c2` source, local `Reproduction1` passes the original
complete inventory journey. Consequently, a local pass alone cannot establish
that the hosted problem is resolved.

People need a reachable way to finish typing, then review, create, save or
cancel an item. Ending text entry must never publish an item, silently change
opening stock, discard an edit, or round a saved price. Ordinary service-item
creation must remain uncluttered.

## Implementation and acceptance scope

- Both catalog creation and editing use a shared conditional bottom safe-area
  control within their current sheet. The control is absent without field focus.
- “Done Editing” clears only the existing shared focus binding. It does not
  save, dismiss, alter draft data or call a provider. Its accessible label and
  hint distinguish it from Create, Save and Cancel.
- The separate keyboard toolbar is removed from these two sheets. Standard
  system keyboard behavior, quantity/date submit handling, input validation,
  current-account boundaries and all item publication paths remain intact.
- The inventory acceptance journey retains all original data assertions. It covers exact price
  `125.375`, opening date `2026-09-08`, fractional quantity `4.25`, invalid input,
  reopening, hardware-style editing to `6.5`, Cancel, and Save with focus active.
  The label check additionally scrolls each required label into view and
  requires its complete text rectangle inside the visible form, below the
  navigation bar. A passive label is not incorrectly required to be a separate
  tappable control; input and Done hit-target checks remain unchanged.
- A separate journey checks the accessible control group, unique action,
  sheet-relative bounds, keyboard non-overlap, portrait/landscape transitions,
  hardware-style entry, hidden idle controls and cancellation back to a blank
  composer. The ordinary hosted iPad workflow explicitly includes this journey.
  Rotation now also requires the application's actual frame to adopt the
  requested orientation before checking controls.
- A separate hosted step on iPad shard 1 exercises both catalog journeys at the
  largest accessibility text size, restores the original device preference on
  exit and retains separate xcresult/log/size evidence. Its verifier requires
  both cases to actually pass, without skips; the normal-size coverage remains.

Apple's current [virtual keyboard guidance](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards)
was read in Safari: use content-appropriate keyboards and keep important
controls usable during text entry. The in-sheet placement is this app's design
choice, not a claim that Apple mandates this specific implementation.

## Evidence

Evidence root:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Inventory Editing.Iz8gS2`.

- Hosted baseline remains in the adjacent `Full Workspace Source.jXImTQ`
  evidence directory. Original diagnostic frames at 88 and 121 seconds show
  the accessory separated from the item sheet; no account-email footer appears.
- `Reproduction1`: unchanged local full inventory journey passes.
- `Candidate1`: the original unchanged inventory journey passes with the new
  in-sheet control. Authoritative xcresult summary and test-tree verification
  confirm one requested case passed without failures/skips. The price-entry
  frame was inspected: Done Editing is inside the sheet, clear of the system
  keyboard, and the original precision remains visible. No email footer appears.
- `Contextual1`: both the original inventory and new contextual UI journeys
  pass with no failures/skips. `MacFull1` verifies 1,877 cases and all three
  requested inventory/catalog suites. `Tools1` passes 74 tests.
- Final source additionally uses adaptive primary tint for this secondary
  editing action and checks its minimum 44-point touch dimensions. Apple’s
  [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility)
  informed this color/target/text-size review. `MacFull2` verifies 1,877 passes
  on this candidate.
- `LargeText1` fails at the first Name-field input at the largest accessibility
  size. The accessibility text-field rectangle includes its stacked label and
  input; the center tap does not focus typing. Retained video/frame and hierarchy
  show the untouched field, not an accounting-data failure. The simulator's
  original `large` text setting was restored. This failure requires a real row
  interaction correction; it is not counted as a pass or bypassed in the test.
- Labeled text-input rows now respond across their full rectangle, using a
  simultaneous tap to set their existing field focus without replacing native
  text selection. The same behavior covers both catalog forms and opening
  quantity/date rows. `LargeText2` passes the original unmodified contextual
  test at `accessibility-extra-extra-extra-large`, including rotation,
  hardware-style selection/typing, 44-point touch bounds and cancellation.
  The simulator setting is verified restored to `large` afterward.
- `LargeText3` runs both full inventory and contextual journeys. The contextual
  case passes; the inventory case creates/reopens the exact item but fails its
  old all-labels-exist-at-once assertion. The 78-second frame shows Purchase
  Cost below the currently loaded/visible rows. This is retained as a failed
  run. The label check will require scrolling each label into view rather than
  assuming an enlarged lazy form has loaded every field simultaneously.
- `MacFull3` executes successfully on the row-focus candidate. Its shell wrapper
  encountered a post-test continuation error after the helper was edited for a
  different mode. No test was restarted: the existing completed xcresult was
  exported directly and verifies 1,877 passes, zero failures/skips and all four
  requested target/suite selectors. Live qualification helpers must remain
  unchanged just like app source until all their invocations have completed.
- `LargeText4` retains a failed inventory case and passing contextual case.
  Inspection finds the visible Item Name label at `{40,277.5,235,63.5}` was not
  a separate hit target; requiring passive-label hittability scrolled it away.
  The corrected check scopes labels to the current form and requires existence
  plus complete visible bounds, while retaining all actual input hit checks.
  This corrects the test's visibility model, not the app's stored data or the
  required labels. `MacFull4` verifies 1,877 passes on the unchanged app source.
- `LargeText5`: both complete inventory and contextual journeys pass at the
  largest accessibility text size, with zero failures/skips. The inventory case
  takes 164.967 seconds and retains every original quantity/date/price,
  invalid-input, cancel/reopen and active-keyboard save assertion. The saved
  large-text frame was inspected: quantity `6.5` and date `2026-09-08` are
  readable with persistent labels and no account-email footer.
- `MacFull5`: final acceptance sources compile on Mac and the full logic target
  verifies 1,877 passes, zero failures/skips and all four required selectors.
  `Tools2` passes all 75 tool tests, including normal and largest-text workflow
  coverage construction. Passing those construction checks does not replace
  actual hosted execution.
- `IPadFull1` verifies 1,883 passes, zero failures/skips and all ten required
  selectors: the complete 1,877-case logic target plus inventory, rotation,
  offline taxable-item creation, invoice opening, simple inbox and field-item
  administrator review UI journeys. Local environment: Xcode 26.6 (17F113),
  13-inch M5 iPad simulator, iOS 26.2, device
  `0ADE5A1A-9859-4377-AD5E-93FC6D70F1D3`.
- Owner-copyback is verified; exact-final-head hosted qualification remains pending.
  The prior published head's backend, Mac and iPad group 2 checks have
  passed; iPad group 1 remains in progress and is not cancelled.
- `Dark1`: contextual journey passes in dark mode; the inspected portrait
  frame shows the neutral editing action inside the sheet, legible against its
  background and clear of the keyboard, without an account-email footer.
- Final app-source Release builds pass without signing: `DeviceRelease2`
  verifies arm64 (SHA-256 `d5fe057a98d4fd6a60dee203366dd33ec06317342e0f86ee7579fdbb377c1826`)
  and `MacRelease1` verifies arm64/x86_64
  (`357346367df34bc7cfcb8bcbd3d491cabc085a300452165aaaf64ce0080ead55`).
  Subsequent changes are acceptance tests/workflow/docs only, not app source.
  Four pre-existing QBO actor-isolation warnings and the Mac Metal-toolchain
  search-path warning remain; they were not suppressed by this change.

Final copyback baseline: `OriginalPreflight5.json` protects seven scoped paths,
417 unrelated owner changes, 410 matching other tracked source files, and the
owner's original branch, HEAD and index. App source has remained unchanged
through final native and release qualification. No failed run was counted as
successful, and no live build/test/CI run was cancelled.

`OriginalCopyBack5.json` verifies all seven files are byte-equal between review
and owner workspaces, all 417 unrelated changes remain intact and the owner's
branch/HEAD/index are unchanged. Only the isolated review checkout is staged.

## Boundaries and remaining gates

No live QBO/Google/customer/vendor/payment writes, CloudKit schema promotion,
physical-device installation, signing change, deployment or merge is included.
The owner checkout's branch, HEAD, index and unrelated edits must be preserved;
only the isolated review checkout may be staged and committed.

This change does not complete automatic full-owner publication/reconciliation,
role-safe full staff projection and activation, durable commands/media,
independent signed-account CloudKit convergence, payment-device handoff or the
remaining competitor-feature and whole-app accessibility/navigation audits.
Mac unsigned builds and logic tests do not prove signed Mac UI interaction.

## Skill steering

Troubleshooting kept observed failure distinct from inferred framework cause;
interface design required actual keyboard and sheet interaction; inventory and
QBO guidance preserved original stock/price/account facts without provider
writes; Xcode and reliability guidance require executed tests, retained failure
evidence and non-destructive delivery. The live audit is
`/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`.
