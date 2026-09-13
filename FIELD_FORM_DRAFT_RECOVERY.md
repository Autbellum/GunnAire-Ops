# Field-form draft recovery — locally qualified checkpoint, 2026-09-09

## Observed gap and requested outcome

At published head `d0faad517d4a8c56e0821d5e6c3b3e67cc8a15b9`, the
field-form editor stores answers only in SwiftUI `@State`. Cancel or process
termination loses unfinished readings. There is no saved draft to reopen. This
does not meet reliable offline HVAC field capture or natural iPad/Mac recovery.

The candidate adds a private device journal and normal job-level recovery,
not a new CloudKit entity or a substitute for the required operational replica.
Completed forms continue to be immutable responses with related job/customer/
invoice/estimate PDF attachments. A draft is never counted for job closeout.

## Boundaries and lifecycle

- The verified company, backend origin, normalized author and actual local
  SQLite store identity scope each job/template slot. Fresh business and job
  authorization is required to open, list, edit, discard or complete it.
- Original questions, answers, customer/site, work type, equipment identity and
  transaction links are retained. Changed context requires review; a retired
  template does not silently relabel answers or make its draft disappear.
- Small edits are saved immediately. Storage errors retain visible entries;
  replacing unsaved entries or discarding a draft requires an explicit choice.
- `editing → completing → completed` retains one response ID, attachment ID,
  activity ID and completion timestamp. An isolated SwiftData transaction commits response,
  attachment and activity together without saving unrelated window edits.
- Reopening a pending completion first checks exact saved response/file identity
  and immutable content. An absent original requires explicit Finish saving;
  a partial or conflicting original requires review, not new IDs. A failed
  journal acknowledgement cannot delete a database commit.
- Explicit discard retains a content-free tombstone. Revision compare-and-swap
  prevents stale windows from overwriting edits or resurrecting discarded work.
- Authenticated encryption covers the scope and slot filename, with a separate
  device-only Keychain key, protected atomic writes and backup exclusion. Lost
  keys, unreadable files and unknown versions are not treated as empty drafts.

The implementation follows Apple's
[CryptoKit AES-GCM authenticated-encryption API](https://developer.apple.com/documentation/cryptokit/aes/gcm)
and existing app Keychain conventions. Native input labels and local status
follow the relevant [data-entry guidance](https://developer.apple.com/design/human-interface-guidelines/entering-data).

## Retained investigation history

Evidence root:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Field Form Drafts.UJXfgu`.
The dedicated qualification helper retains log, xcresult, summary and actual
test identities under unique tags. MacFocused1 compiled and ran 42 cases with
five failures in draft listing. Direct reads succeeded, while directory
enumeration supplied relative-base URLs which failed strict URL-object equality.
The correction compares standardized absolute paths while retaining exact
scope, slot filename and authenticated-content checks. MacFocused2 verifies all
42 cases passed, with zero failures/skips and both actual suite identities.
The new default-export closure actor warning is corrected without suppressing
concurrency diagnostics. All 74 Tools cases pass in Tools1.

IPadFocused1 passes all 19 new logic cases. Its three UI journeys stop at a
test-only input lookup that assumed the multiline SwiftUI field was a TextView;
they are not credited as working journeys. The revised tests locate the exact
input accessibility identifier and retain a frame and accessibility tree before
typing, so the next run can distinguish a lookup assumption from a real view
failure. These first failed results remain retained.

Additional review keeps a pending completion reachable when its immutable
response already exists, while active drafts replace the ordinary template link
with Resume instead of adding duplicate entries. Four added logic cases check
customer/property/equipment/invoice/estimate lineage and reject incomplete
answers represented as a completing record. MacFocused3 and IPadFocused2 are
running against this next frozen source; earlier passes do not qualify it.

MacFocused3 passes all 46 focused cases. MacFull1 verifies all 1,822 actual cases
with zero failures/skips and all six required selectors. IPadFocused2 passes all
23 new logic cases, and confirms saved text survives abrupt termination and
relaunch. Its UI failures remain unqualified: the native hierarchy proves the
test tapped a broad labeled Switch row (value remained 0) rather than its nested
63-point control. A separate genuine lifecycle issue left retired drafts hidden:
an initially empty Group had no child on which to run onAppear. The correction
uses a stable zero-height-when-empty container and the real switch target with an
explicit value assertion. MacFull2 and IPadFocused3 qualify the resulting source.
The first current-form frame has been visually inspected: readable native
fields, short local status and no account-email footer. It is not whole-app
accessibility or final-run UI acceptance.

Added logic cases cover incomplete durable drafts, ciphertext privacy, separate
reader instances, scope/job separation, stale windows, discard, corruption,
copied files, lost keys, invalid versions/answers, storage limits, revoked roles,
reassignment, changed equipment/templates, duplicate job identities, atomic
completion, interrupted PDF/database/acknowledgement writes, missing original
files, explicit repeat inspections and unrelated unsaved model edits.

Added isolated iPad journeys use ordinary Schedule → Job Documentation → Work
navigation, abrupt termination, original draft recovery, explicit completion,
lost acknowledgement recovery and retired-template discard. They do not open
production CloudKit or call provider transports.

IPadFocused3 exposed a test-fixture defect: ordinary launch seeding deleted all
fixture customer attachments, including the original completed file needed for
lost-acknowledgement recovery. The dedicated DEBUG-only draft fixture now preserves
its existing isolated store across relaunch. No production startup, CloudKit
configuration or ordinary fixture-reset behavior changes. IPadFocused4 then passes
all 28 selected cases, including all three recovery journeys.

Final review added original activity identity/content checks and upload callback
authorization. The file upload rechecks access and exact original response,
attachment, activity and PDF bytes before dispatch and after either success or
failure. Revoked access or changed original data makes a late result a no-op.
Recovered completions do not automatically upload another copy. Malformed or
failed provider responses retain the locally saved original for attention.
These transports are injected in tests; no provider/customer write is made.

## Final local qualification

The following results qualify the final frozen native source, superseding the
intermediate runs above. Every named native test run has zero failures/skips;
the execution verifier checks actual case identities, not just Xcode exit status.

| Evidence tag | Verified result |
| --- | --- |
| MacFocused5 | 53 cases; draft and existing field-form payload suites |
| MacFull4 | 1,829 cases; all six required suite selectors |
| IPadFull1 | 1,836 cases; all 13 selectors, including seven UI journeys |
| Tools2 | 74 cases, including workflow and actual-execution verifier checks |
| Backend1 | 852 cases; local regression, no live provider calls |
| DeviceRelease3 | Unsigned Release build; arm64 architecture verified |
| MacRelease3 | Unsigned Release build; arm64 and x86_64 verified |

The three draft UI journeys cover abrupt termination, original-answer recovery,
completion without duplication, lost acknowledgement, and retired-form recovery
with explicit discard. The four additional journeys verify invoice workspace
opening, simple mail, immutable saved-form history and required forms in normal
job navigation. Mac UI execution is not claimed; its existing unsigned UI-runner
Gatekeeper gate remains unresolved.

Environment: Xcode 26.6 (17F113), shared GunnAire Ops scheme, Debug test builds
with CODE_SIGNING_ALLOWED=NO; Mac Catalyst arm64 and the existing 13-inch M5
iPad simulator running iOS 26.2. The retained qualification helper is
`/tmp/gunnaire-workflow-validation.NYZ8uS/qualify_field_form_drafts.sh`; it records
the exact xcodebuild destinations, selectors, result bundle and verification
commands. The source keeps its existing deployment target and dependencies.

Final unsigned binary SHA-256:

- DeviceRelease3: `33051872288e0c487464b784f986e248c564f12899ce3f4283496df8438f64d1`
- MacRelease3: `3070e9dbc2f807e6b28c8d9967dbee24802619dcdb752cc7a48ac8e994cdb398`

The final IPadFull1 attachment frames were visually inspected for the completed
form and saved-form handoff, required forms in job documentation, simple inbox
and compose sheet. They retain ordinary controls and readable field values,
without raw code or an account-email footer. Functional mail addresses remain
in mail content. This is scoped portrait iPad review, not whole-app accessibility,
large Dynamic Type, Mac UI or production-mail acceptance.

## Preservation and publication

OriginalPreflight2 protects the exact 12 checkpoint paths, 378 unrelated changes,
387 matching other tracked source files and the owner's original branch, HEAD
and index. Final copy-back verification passes: all 12 files are byte-identical
to the qualified review source, all 378 unrelated changes are preserved, and
the owner's branch, HEAD and index are unchanged. Commits are made only in the
isolated review checkout; no staging or commit is performed in the owner's project.

The already-published parent d0faad5 and workflow commit 517858f are verified in
[PR18](https://github.com/Autbellum/GunnAire-Ops/pull/18). Its
[Backend run 34390624919](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34390624919)
and [native run 34390624697](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34390624697)
are now completed successfully, including both iPad groups and Mac. Their
success qualifies that published parent, not this unpublished checkpoint.
No live predecessor run is cancelled by publication.

For the earlier e7c6c8a run, retained PredecessorTimeout2.log shows repeated
60-second animation/quiescence waits inside the same inventory UI journey for
more than 3,300 seconds before GitHub's automatic 90-minute timeout. This narrows
the next recurrence investigation; it does not prove an app defect versus a
test/runner problem, and no blanket animation disabling, timeout increase or
coverage reduction was made. The newer parent run completes successfully.

The three new draft UI selectors are locally qualified but are not yet added to
the GitHub workflow's existing selector list. The full logic target includes the
new logic cases automatically. No workflow file or credential scope is changed
by this checkpoint; broader CI UI coverage remains a separate gate.

## Remaining full-suite requirements

This candidate does not complete the broad business-suite goal. Independent-user
CloudKit convergence, complete authorized staff operational storage/commands,
provider/vendor acceptance, signed device and payment/Handoff acceptance, wider
iPad/Mac usability/accessibility and the existing completion matrix gates remain
required. Drafts are explicitly private to this device; cross-device draft
handoff is not claimed. The existing document-upload transport is reused; a
durable remote upload ledger and independent-staff document command acceptance
are not newly solved here. Large-retention journal performance remains unqualified.
No schema, entitlement, signing, deployment or live
accounting/payment/customer mutation is performed by this checkpoint.
