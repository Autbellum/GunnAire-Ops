# Tax-address input synchronization

Follow-up: hosted head `6a0a38e` later failed on the initial `Cancelled address`
input remaining at its placeholder, not this earlier partial-street snapshot.
`NATIVE_CI.md` records the exact new failure and unresolved cause. The local
repetitions below and the original recording do not establish current hosted
acceptance; further reproduction is required.

## Observed failure and discriminating evidence

The hosted iPad job for PR head `a9dd55c` failed the existing
`testTaxAddressReviewKeepsDraftPricesAndReturnsToBilling` assertion immediately
after `typeText("12 Main Street")`: the accessibility value was `12 Main`.
This happened before city/state/ZIP entry and before saving or publishing.

The exact completed-job artifact was downloaded read-only from GitHub artifact
`10037004996`, run `34173159975`, job `101897274113`. Its 211,376,085 bytes match
GitHub's SHA-256:
`450c8d20ab7ef9e18d35e441b4836ee2a42e3e196006b7996249feb919a37dbc`.

The retained recording proves a timing mismatch rather than permanent loss of
the final characters in this failure:

- At recording time 67.935 seconds, the focused field visibly contains `12 Main`.
- At 68.350 seconds, without another test typing request or app action, the same
  field visibly contains the complete `12 Main Street`.
- The test activity queried the field at 67.838 seconds and recorded its
  immediate-equality failure at 68.477 seconds. The last recording frame already
  shows the requested complete address.

Times are relative to the screen recording's 1788829092.036 start timestamp.
This evidence explains this exact hosted failure; it is not a claim that every
possible input, keyboard or address-validation issue is resolved.

The prior preceding-head failure on `f082074` has a similar incomplete-input
symptom (`12 Main S`), but its recording has not been inspected here. The current
unchanged source also has local passing evidence. Neither fact substitutes for
the exact original recording above.

## Correction and qualification

The field-value helper now waits up to five seconds for the exact requested
value before moving on, then retains its original equality assertion. It does
not retype, replace the field, shorten the expected address, change app behavior,
skip a test, or permit partial values.
Cancellation, disabled-invalid confirmation, explicit sale-location choice,
unchanged sold prices, invoice saving, and reopening the original job remain
required assertions.

The unchanged baseline passes all five repetitions in
`UnchangedFiveRepetitions.xcresult` on the 13-inch M5 iPad simulator, iOS 26.2.
That run built the original test from head `442e9d7` before the correction. Its
test source SHA-256 is
`c65cf8f55810b9ccd98b1483435fe94f407da54e575a24f318836d1d3c9f8033`.
Local baseline passes are not treated as disproving the recorded hosted race.

The initial correction, source SHA-256
`865a3dd2b5f8e2fc2d1bfc85a16d142cd06321ad66639cfd6769922232135597`,
passes eight of nine executions in
`CorrectedThreeJourneysThreeRepetitions.xcresult`. The remaining failure is a
different premature snapshot: after Cancel and immediate reopening, the test
read `""` instead of the exact expected `Street address` placeholder. Its local
recording `LocalReopenFailureAttachments/E6F44C27-FFC7-4018-9EA6-572EDC0F789B.mp4`
shows the sheet mid-presentation; the final frame at 28.1017 seconds visibly
shows the expected empty field with its placeholder. Both fully completed
tax-address repetitions passed, as did all six Invoice/Mail executions. This
intermediate run remains a failure, not a successful qualification.

The final correction also explicitly waits for sheet dismissal and reopening,
and applies the same exact-value helper to the empty placeholder and retained
street/city values. Every original expected string remains unchanged. It never
substitutes empty-or-partial alternatives or repeats Cancel/Save to force success.
The final test source SHA-256 is
`431ef4eb7437dd1c7be41de28c0a4aabbd90c3535f08abd2c936c99c68b23b4a`.
`FinalThreeJourneysThreeRepetitions.xcresult` passes all nine executions:
tax-address, Invoice-open and simple-Mail journeys, three times each, with
relaunch between repetitions. There are no failures or skips. The matching log
ends with `TEST SUCCEEDED` and has no compiler warnings/errors. App source,
models, project settings and workflow YAML are unchanged; prior full logic and
universal Release results therefore remain evidence for the same app source,
not newly executed tests for this test-only correction.

The final retained form screenshot was visually checked: all four address
values, the explicit sale-location switch, Cancel and Use addresses are visible;
there is no account-email footer. This is diagnostic UI evidence, not an App
Store screenshot or a claim of physical-device acceptance.

Both commands use scheme `GunnAire Ops`, Debug, signing disabled, serial testing,
the established build mirror `/tmp/GunnAireQBOBuild.LvvxSD`, simulator ID
`147D4CB6-85CC-4B17-BD35-8684E60E672D`, and
`-test-repetition-relaunch-enabled YES`. Repetitions use `-test-iterations`,
never retry-until-success. Every requested repetition must pass. Hosted
qualification of the published fix is separate from local results. No merge,
deployment, signing or provider mutation is part of this correction.

## Retained evidence

Local root:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Tax Input Diagnosis/`.

- `HostedIPad-a9dd55c.zip`: digest-verified original artifact.
- `HostedArtifact/iPad.xcresult`: original result bundle.
- `HostedFailureAttachments/C85E448B-28F0-4CA2-9F46-A421C0C75B3E.mp4`: original recording.
- `HostedFailureAttachments/Frame-68.0.png`: actual time 67.935, partial value.
- `HostedFailureAttachments/Frame-68.41833333333332.png`: actual time 68.350, full value.

The full application goal remains open. This makes the tax-address acceptance
check match the user-visible input lifecycle; it does not establish complete
QBO synchronization, staff CloudKit sharing, physical Tap to Pay/Handoff,
vendor availability, production readiness or flawless end-to-end behavior.
