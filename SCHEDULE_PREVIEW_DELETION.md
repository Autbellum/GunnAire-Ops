# Schedule preview deletion crash

Candidate, September 9, 2026. The exact published source `3a6d94a` fails native
run `34338126967`: iPad group 1 exits 65 with two failing UI journeys, while
group 2 reaches GitHub's one-hour timeout. Backend Python 3.13/3.14 and Mac pass.
No live job was cancelled or restarted while collecting this evidence.

## Evidence and correction

The original iPad group 1 artifact is retained under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Hosted iPad Failure.jCAP9G`.
Artifact `10100512224` was checked against the exact run/head, length
311,518,787 bytes and GitHub SHA-256
`24b606db3ae4b14c5d0c2e2ead031358a7f4c33b78b3bb188054f7ff9cb9931a`.
Credentials were not forwarded to artifact storage; original recordings, logs,
result bundle and crash diagnostics remain available.

The crash at 10:52:52 UTC is an EXC_BREAKPOINT on the main thread. Its stack
reads `ServiceCall.type` through `ScheduleView.displaySubtitle(for:)`, line 1725,
from the lazy `snapshotSection` row after the unbilled event was deleted/saved.
The screen's retained model object had been invalidated by SwiftData deletion.

Upcoming Snapshot now materializes immutable title, subtitle, date, routing
availability and original identity values before constructing lazy row closures.
Preview taps resolve the original persistent identity from the current
role-filtered live list. Missing, duplicate, deleted, replacement or wrong-context
objects cannot be opened. The deletion confirmation likewise retains identity and
title values, clears presentation before deletion, and resolves the currently
visible original before the existing authorization/history/Google checks.

This does not relax deletion policy, delete billed history, replace cancellation,
or change Google Calendar writes. The row still shows the same information.
The model tests cover saved deletion with a retained query, pending deletion and
rollback, current visibility, wrong context, duplicate/replacement identity, and
readable preview/confirmation values after deletion.

## Regression setup and unresolved hosted input

The unchanged-source local reproduction passes both previously failing UI
journeys. That establishes intermittent behavior, not that the hosted errors
were imaginary. The new schedule UI regression retains cancel/confirm/billed-job
assertions and additionally requires the original preview before deletion, its
removal afterward and the app remaining foregrounded.

The first two candidate UI runs stop at the new initial preview assertion. The
retained hierarchy shows a `Proposal-only customer` job left by an earlier test
occupying one of the three preview slots. A Debug-only, explicit test-store UUID
now isolates this journey without deleting another test's database or accepting
arbitrary file paths. The same UUID can retain a test's state across relaunches.
Its unbilled fixture is scheduled at the end of the current test day so runner
timezones do not turn it into a past event before preview verification. Production
store configuration and real appointment dates are unchanged.

Separately, the estimate failure observes quantity `1` instead of `2`. Original
video frames show the keyboard appearing during the synthesized deletion/input
sequence. It passes the unchanged local reproduction, but this checkpoint does
not establish a fix for that hosted input-delivery problem. No expected value,
keyboard journey or CI selector is removed. The second iPad job timed out while
still completing UI tests; it is not a test-suite pass.

## Final local qualification

`MacSchedule1` passes the three initial preview cases and 45 Google Calendar
workflow cases. After fixture isolation, `IPadSchedule3` verifies all four
preview/isolation cases and the strengthened deletion journey (5 actual cases).
The final full runs are retained in `Staff Model Semantics.265WOl`: `MacFull2`
verifies 1,721 cases, and `IPadFull1` verifies 1,729 (all logic and eight exact UI
journeys), including deletion, invoice opening, simple shared Mail, all three
bundle editors and both staff setup/recovery paths. No failure/skip is present
in those passing final runs; the original failed results remain retained.

The exact deletion journey passes twice after fixture isolation, taking 31.462
and 31.460 seconds. The final full-run estimate journey also passes, but this does
not prove the intermittent hosted input problem fixed. Four final-source
screenshots were visually inspected without account-email footers. Both unsigned
Release builds, required binary architectures, all 71 Tools tests, unchanged
workflow lint and diff checks pass. See [model qualification](STAFF_MODEL_SEMANTICS.md)
for binary hashes and copy-back preflight. There is no production deployment,
signing/CloudKit schema change, physical install, live provider write or main merge.

Fresh exact-head hosted verification remains required, including the unresolved
runner input/time-budget issues. Apple's [ModelContext documentation](https://developer.apple.com/documentation/swiftdata/modelcontext)
was read in Safari, including deletion/save lifecycle and context ownership.
This is not full-app or signed CloudKit/provider/payment acceptance.
