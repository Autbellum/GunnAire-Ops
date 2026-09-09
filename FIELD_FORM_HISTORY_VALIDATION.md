# Field-form history and closeout validation

September 9, 2026. Isolated checkpoints `1a79391` and `546bb70` are now integrated
into the review checkout at `e7c6c8a` for combined-source qualification. The form
changes are now copied byte-for-byte to the owner checkout, but not published.
The independent
inventory/discriminator candidate `e7c6c8a` is already copied and published.
The original isolated branch `codex/field-form-history-20260909` remains intact.
Final copy-back verification confirms all 13 scoped paths are identical and
preserves all 368 unrelated changes plus the original branch, HEAD and index.
The review-branch checkpoint remains local while predecessor native CI runs.

The integration check compared every form file with its isolated source and
verified that the two overlapping files retained the complete prior review-branch
changes. It caught an ambiguous patch context placing a UI test-store argument
on the wrong test; that was corrected using the exact function context before
any build. All 12 form paths and both overlapping changes then verified.

The only subsequent behavioral polish removes the duplicate PDF warning banner
when the original-history review notice is already shown. It still prevents new
completion-PDF generation and leaves the original record untouched. Real export
failures keep their own actionable message. The UI regression now asserts the
absence of that redundant banner while preserving all original checks.

## Combined-source qualification

Evidence root:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Field Form Integration.vse4Kh`.
The candidate combines the published inventory/discriminator changes at
`e7c6c8a` with the two isolated form checkpoints and the warning-banner polish.
It is frozen while native checks run; no isolated result substitutes for this
combined app. The helper's relationship-suite name was corrected to the actual
`StaffWorkspaceRelationshipGraphTests` before starting any combined run.

`OriginalPreflight1.json` records 13 copy-back paths, 368 unrelated original
changes, 379 other matching tracked sources, and the original branch, HEAD and
empty index. All 11 non-document candidate files are fingerprinted. Generated
copy-back patches include 24 context lines to disambiguate repeated UI-test
launch arguments; exact byte equality is still required after application.

`MacFocused1` and `IPadFull1` started on September 9 after verifying that no
previous local Xcode process remained live. Mac selects the five relevant form,
staff graph/model/discriminator and inventory suites. iPad selects the whole
logic target and 14 real UI journeys, including invoice/mail opening, exact
inventory, keyboard-active billing, catalog approval, staff access/recovery and
all three form journeys. Final success requires actual xcresult case identities,
not just a green build exit or test discovery. `MacFocused1` passed all 68 actual
cases with zero failures/skips and all five suite identities verified.
`MacFull1` then passed all 1,791 actual logic cases, zero failures/skips, with all
16 required suite/legacy identities verified. `DeviceRelease1` passed the
unsigned arm64 iOS Release build and architecture check, with binary SHA-256
`0e099b7a718e00d3d3c7843bc5df0d18a43a78647f6d1406c94fb54c6b355f97`.
`MacRelease1` also passed the unsigned universal Mac Release build and
arm64/x86_64 architecture check, with binary SHA-256
`519f66aa56a9d869474162561c17830109d7a933aee2bd9fca36c93adde3d861`.
`IPadFull1` passed all 1,805 actual cases: 1,791 logic cases and all 14 selected
UI journeys, zero failures/skips, with all 30 required target/suite/legacy/UI
identities verified. The original source fingerprints are unchanged.

Eight selected final-run iPad screenshots were visually inspected: template
management, required forms in job Work, both original/review history states,
saved fractional inventory, saved estimate and invoice, and the simple inbox.
The complete saved-template title/scope/required status is visible. The original
question and Pass answer remain clear; invalid history has no extra export-error
banner or new PDF action. Inventory retains 6.5 and the original date and price.
No account-email footer appears. The job editor's numerous empty condition fields
and the admin catalog's dense secondary information remain presentation work;
these frames do not prove every action fits without scrolling or large-text QA.

After every iPad UI test ended, `MacUI1` attempted the same form/history, invoice
and simple-mail journeys on unsigned arm64 Mac Catalyst. It failed before any
test executed. Xcode's final result is “The test runner hung before establishing
connection” (exit 65). The live runner sample was still at `_dyld_start`; the
system log and native dialog showed Gatekeeper rejecting the generated runner
as damaged. Read-only codesign verification reported “code has no resources but
signature indicates they must be present.” The runner and app source were not
replaced during that attempt.

The two observed damaged-runner alerts were dismissed with Cancel, not Move to
Trash, after confirming this launch/signature failure. No file was deleted,
security setting weakened, signing identity changed, test restarted, or failed
result relabeled as a pass. The same Xcode process then finished with its original
failed result. Mac UI acceptance requires a properly signed local test harness
or another verified runtime path; Mac logic/Release passes do not establish it.

`MacFull1-PDFReview` contains both actual current-run field-form PDF attachments.
All three rendered pages were inspected: the original required choice and Pass
answer are legible on the verified completion; unreadable history is explicitly
Recorded / Needs review on the repair report, without raw data, clipping or an
email footer. The surrounding report still has empty Equipment and Service Notes
headings and repetitive readiness information. Those existing layout gaps remain
open; the document is not claimed to meet final whole-suite presentation quality.

The combined checkout passes all 852 Backend cases (`Backend1`, 128.785 seconds),
all 74 Tools cases and both unchanged workflow actionlint checks. The Backend
suite used isolated local test servers; no production/provider request was made.
The native workflow on the published `e7c6c8a` head is still
running in GitHub run `34380679032`: its Mac job has passed, while both iPad jobs
remain live. Backend run `34380679091` has passed on both Python versions.
No successor push cancels that live run.

Code review confirms that the response editor still holds unfinished answers
only in view state. Relaunch/dismissal draft recovery remains incomplete; this
checkpoint's failed-template-save recovery does not prove response-draft
persistence. Broader accessibility, Mac UI, copy-back and exact-head hosted
qualification likewise remain separate gates.

The PDF presentation follow-up has a concrete source location:
`CustomerDocumentExporter.drawSection` always draws a heading before checking
whether any row has a nonblank value, matching the two empty headings in the
current repair-report rendering. It also moves an oversized row to another page
without splitting that row across pages. Long-answer pagination therefore needs
its own reproduction and layout acceptance; these short fixture PDFs do not
prove it. No rendering source is changed during the frozen native qualification.

## Saved-history and template recovery follow-up

The job Documentation Work stage now links to **Saved forms**, including
unreadable/orphaned records that cannot satisfy the current form requirement.
The list itself filters the original job ID and orders records deterministically
by recorded time and ID. Invalid history uses **Original record / Recorded**,
explains why answers cannot be displayed, and never offers to generate a new
completion PDF. Valid older answers retain their retired template's labels and
choices after a same-title revision. No record is rewritten by reading history.

Template creation/revision reports the new saved identity back to the manager,
which reveals that row after the sheet closes. It uses the normal Form and
ScrollViewReader, without timed scroll retries or an alternate test interface.
Revising or duplicating unreadable setup requires explicit office review of the
fields, job types and closeout requirement before Save becomes available.

Failed template persistence now removes only the unsaved inserted candidate and
restores the original active flag. It does not roll back unrelated context edits.
Failed activation/deactivation likewise restores the previous status and displays
an actionable error instead of silently leaving an unsaved change on screen.

The new DEBUG-only history fixture requires the existing isolated UUID test
store, disabled CloudKit, authenticated-admin test mode and collectible-job seed.
It populates ordinary models for two jobs and uses real Schedule → Documentation
→ Work navigation; it installs no alternate UI, transport or production access.

`MacRecovery1` and `IPadRecovery1` failed compilation in a new test assertion's
macro expansion before executing tests. Splitting the expected ordered-ID array
into typed local values corrected that assertion without changing its meaning.
`MacRecovery2` verifies **23 actual payload/history tests**, zero failures/skips,
including original-job ordering, failed revision/retry with an unrelated draft,
failed create without a phantom record and failed active-status changes.
`MacVerified1` passes the complete **1,778-case** logic target, zero failures/skips,
with all 12 required suite/legacy selectors verified against actual execution.
`IPadRecovery2` contains two passing UI journeys and one failure. Saved-history
navigation passed, including both original-job records, exclusion of the other
job, review-only malformed history, original retired question/answer, PDF action
only for valid history and return to the same job. Both retained history frames
were inspected; no raw JSON, clipped content or email footer appears. The review
screen still repeats the explanation across the status/answers/PDF areas; this
is remaining interface polish, not a claim of finished whole-app simplicity.

The failed template assertion expected **Required for closeout**, but the screen
recording shows the switch stayed off before Save and the saved row correctly
remained optional. The test's center-of-row tap targeted blank space instead of
the visible trailing native switch. The driver now targets that visible switch
and immediately verifies `0 → 1`, without retrying the action or weakening the
saved-state/viewport assertions. This changes only the UI-test driver, not the
app source under the Mac Release build. The final recorded row's title and
subtitle were fully visible after the new automatic scroll.

`IPadVerified1` passes **1,781 actual cases**, zero failures/skips: complete
1,778-case logic plus all three UI journeys, with all 15 requested suite/legacy/UI
selectors verified. The corrected switch action proves `0 → 1`, and the saved
required status is fully inside the form viewport without another scroll.
All four named final screenshots were exported and visually inspected. The
template title, scope and required status are fully readable; valid and invalid
history keep the original customer/job context, with no account-email footer.
The job's surrounding empty condition fields remain visible polish work.

`MacRelease1` passes the unsigned Release build and arm64/x86_64 architecture
checks. Its binary SHA-256 is
`9bf4c3963f4f117c68ecfce083a4817d5ad40a8e94a6ab91f78f6c6001028c97`.
All 74 Tools tests, both workflow actionlint checks and `git diff --check` pass.
No field-form compiler warning remains. `DeviceRelease1` also passes the unsigned
arm64 iOS Release build and architecture check. Its binary SHA-256 is
`51ff8702abcaae76a4866392abc337fed5330cddc77dc690dd19d092ab92de44`.
These Release hashes qualify the isolated checkpoint, not the subsequent combined
source or banner polish. No device install, signing mutation, provider request or
deployment is part of this checkpoint.

## Evidence and corrections

The prior response reader accepted any numeric snapshot version, used bridged
JSON booleans, and constructed a dictionary from unchecked duplicate question
IDs. Duplicate IDs could trap; malformed responses could appear empty while
still satisfying closeout through their template ID or title. Startup migration
also treated unreadable/future assignments like recognized legacy arrays.

The candidate parses bounded JSON without losing duplicate (including escaped)
keys, requires exact supported object shapes and types, rejects duplicate UUIDs,
and validates question kinds, choice options, assignment types and response
metadata. Owner-transfer codecs remain lossless; invalid raw strings are kept
for review rather than normalized, deleted or silently replaced. Unfinished
structurally valid records remain representable but do not count as completion.

New responses use version 2 and retain the complete original question and choice
list beside their answers. Version 1 snapshots remain readable and are compared
with their original template when available. An old choice response whose
original options are unavailable needs review; options are never inferred from
a revision. Historical UUID-keyed answer dictionaries use JSONEncoder's actual
alternating key/value array representation and need the original template for
completion. The old empty-object sentinel is unfinished, not completion proof.

Closeout, the job form list and billing documentation resolve original versions
consistently. Known optional forms and other work types do not become invented
requirements when questions need repair. Unknown active assignments stay visible
for office review and cannot silently bypass closeout. New-form save and new
completion-PDF generation reject invalid data. Existing linked PDF bytes are
retained; response/job/customer links are checked before using the supplied file.
Reports identify unverified history as needing review rather than completed.

The full-workspace relationship preflight now validates both field-form entity
families before detached reconstruction. This does not activate the full staff
store, distribute raw owner records, grant access or send provider mutations.
Authorship, timestamp, job identity and original raw data remain unchanged.

## Qualification in progress

Evidence root:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Field Forms.PrRs1X`.
Xcode 26.6 (17F113), unsigned arm64 Mac Catalyst, independent derived data.

`MacFocused1` actually passed 32 cases across the new payload tests, relationship
tests and complete-model tests. Its requested qualification nevertheless failed:
Xcode omitted ten individually selected Swift Testing methods. The execution
verifier detected every omission; the green xcodebuild exit is not treated as
coverage for those ten tests. `MacFull1` passed **1,773 actual cases**, zero
failures/skips. The verifier confirms the complete target, new payload suite,
and all ten legacy method identities in the actual result tree (12 selectors).
`MacFull2` passed **1,774 actual cases**, zero failures/skips, including the same
12-selector execution audit and direct JSON-reader resource/syntax coverage.
The explicit nonisolated/Sendable plain-data types compile without field-form
warnings. `MacFull3` passed **1,775 actual cases**, zero failures/skips, verifying
the original-template report handoff and both historical snapshot and dictionary
choice responses. All ten original field-form tests executed; 12 selectors were
verified. Final app source in `MacFull4` passed **1,775 actual cases**, zero
failures/skips, including all 20 new payload/history tests. No field-form compiler
warning remains. The platform-independent export errors are covered explicitly.

All 74 Tools tests and both workflow actionlint checks pass. The workflow files,
signing, schema, server and provider configuration are unchanged. The newly exposed
snapshot Encodable actor-isolation warning is corrected and qualified on Mac;
pre-existing QuickBooks actor warnings and the optional Mac Metal path warning
are separate and have not been suppressed.

`PDFReview1` contains both actual test attachments from `MacFull1`: a one-page
verified completion and a two-page repair report with unreadable history. All
three rendered pages were inspected. The review status is legible, not clipped,
and does not claim completion. No email footer appears. The overall report still
has empty equipment/service-note headings for this incomplete fixture; that
existing report polish gap is not claimed fixed. The report's field-form section
now receives the already-available original-template collection, so valid legacy
choice history can agree with closeout rather than requesting unnecessary review.
That follow-up passed in `MacFull3`.

The separate M5/iOS 26.2 simulator
`BEFCCCDA-689B-4825-86AE-09F29ADD4FA7` was created and fully verified Booted in
20 seconds; no existing simulator was reset or retargeted. `IPadFull1` failed
compilation before any tests: the new export guard's Cocoa validation constant
requires CoreData to be imported on this platform. A plain application-domain
error now replaces that accidental module dependency, preserving distinct
wrong-job and invalid-history messages. `IPadFull2` runs the complete logic suite
plus original template-creation and job-work-stage UI regressions on the same
prepared device with independent derived data. No compiler failure or omitted
test is counted as a pass. `IPadFull2` passed **1,777 actual cases**, zero failures
or skips: 1,775 logic cases and both selected UI journeys. Its execution audit
verified 14 selectors, including the ten legacy field-form methods. Both runs
have ended. App source remains unchanged; only two keep-always screenshot
attachments were then added to those UI tests for `IPadVisual1` visual review.
`IPadVisual1` passed both actual UI tests, zero failures/skips. Both named
screenshots were exported and inspected: template management after saving and
the job Work stage with the two required Service forms. The form actions and
readiness are legible, and neither screenshot has an email footer. The saved
template sits at the bottom of the current list viewport with part of its
subtitle below the edge; automatic reveal of the new row remains polish work.
The surrounding job screen also exposes many empty condition inputs. The field
form section is compact, but the whole job editor is not claimed streamlined.

`PDFReviewFinal` contains the two PDFs from final app source in `MacFull4`.
All three rendered pages were inspected again with the same legible status and
no clipping/overlap/email footer. These are fixture QA artifacts, not documents
sent to any customer or provider.

The follow-up above now qualifies saved-history navigation and saved-row reveal.
Remaining qualification includes empty-field and repeated-message presentation,
field-form draft recovery, broader accessibility/large-text and Mac UI acceptance,
combined-source iPad/Mac and Release verification with the published inventory/
discriminator candidate, preserved-state copy-back, and exact-head hosted checks.
The isolated arm64 iOS Release has passed as recorded above; it is not evidence
for the combined build. This is not evidence of signed-device or live
independent-account CloudKit acceptance.

The full goal still requires the remaining nested domain contracts, role-safe
full staff projections, versioned server ledger, isolated encrypted staff store
and lease, durable field commands/conflicts, authorized file bytes, provider and
vendor acceptance, iPad-to-iPhone payment handoff/Tap to Pay, and complete iPad/Mac
navigation and accessibility qualification. No narrow test result completes it.
