# Native GitHub Actions checks

## Shared field-payment handoff review coverage

The candidate workflow selects **58** iPad UI journeys: all prior 54, plus the
app-wide field prompt, shared financial verification without device QBO OAuth,
offline/missing-number/open-attempt/paid states, and unpublished-invoice recovery.
Two disjoint groups of 29 retain the complete logic target; Mac retains its full
logic suite and unsigned universal Release. Existing assertions, read-only
permissions, time limits and actual-execution verification remain intact.

See [shared payment review](FIELD_PAYMENT_SHARED_REVIEW.md) for exact source and
qualification. These new selectors are not yet published or hosted-qualified.

## Shared original-file recovery coverage

The prepared shared-recovery workflow selects **54** iPad UI journeys, retaining
all previous 52 and adding shared-original restore/offline export and unavailable
shared-history recovery. Two disjoint groups each execute 27 journeys plus the
complete logic target. Mac still runs its complete logic target and unsigned
universal Release build. Read-only permissions, job limits, pinned actions/Xcode,
actual execution verification and evidence retention are unchanged.

The real workflow selection script passes all three shard tests within the full
55-test Tools suite. Local final-source acceptance confirms 1,468 logic cases on
each platform and all seven selected iPad UI journeys (1,475 actual cases).
See [shared-file qualification](NATIVE_QBO_DOCUMENT_RECOVERY.md) for exact evidence
and remaining signed-device, provider and full-suite gates.

Prepublication status at `a02e838`: Backend run `34260770295` succeeds on both
Python versions; native run `34260770325` has a successful Mac job and two iPad
jobs still in progress. These results do not qualify later source. Publication
to existing PR #18 and exact-head hosted status must be checked separately.

## Original-file recovery and bounded iPad groups

The preceding workflow selects **52** iPad UI journeys: the previous 48 plus the
Receipts & Bills workspace and three original-file recovery journeys. It splits
that declared list into two disjoint groups of 26, with the complete native logic
target on each. Mac retains its full logic suite and unsigned universal Release
build. All assertions, the actual-execution verifier, read-only permissions,
existing job limits and evidence retention remain. Artifact names include the
group index to prevent collisions.

`Tools/test_native_workflow_shards.py` executes the workflow's real selection
script (without xcodebuild/network) and verifies complete, disjoint coverage,
existing method names, retained Mac coverage and rejection of invalid group IDs.
The complete Tools suite runs in both hosted Backend jobs.

This addresses explicit hosted evidence: native run `34245007258` at published
head `c9af5d7` passes Mac but its iPad job is **cancelled after exceeding 60
minutes**. Backend run `34245007214` passes both Python versions. It is not a
complete green head, and this new source/workflow still needs exact-head hosted
qualification. No previous selector is removed to fit the time limit.

See [native file recovery](NATIVE_QBO_DOCUMENT_RECOVERY.md) for candidate source,
local acceptance and the remaining provider, shared-device and full-suite gates.

## Native category and bundle composer coverage

The workflow adds three actual composer journeys (37 selected UI tests):
invoice and estimate category browsing, independent repeated-member edits,
original document save/return, and direct Save after hardware-keyboard Select
All. All 34 existing UI selectors, complete logic targets, read-only permissions,
unsigned universal Mac Release and job limits are retained.

After xcodebuild, `Tools/verify_native_test_execution.py` checks the actual
xcresult tree against every requested selector. An absent UI method fails even
if all 1,365 logic tests pass; a zero-test success, skipped/failed method, wrong
target or malformed result also fails. The full Tools suite tests this verifier.
The workflow retains the detailed test tree beside its existing summary.

See [native bundle composition](NATIVE_BUNDLE_COMPOSITION.md) for exact local
qualification, retained discovery/keyboard failures and the full remaining
scope. This candidate requires its own exact-head hosted run after publication.
Corrected local source passes 1,365 logic tests on each native platform, all
eight selected iPad journeys, 546 Backend tests, 51 Tools tests and unsigned
universal Mac Release. The execution verifier confirms the actual selected
methods rather than treating an xcodebuild success message as sufficient.

## Completed hosted result at the bundle-transaction head: `5d16fb8`

Verified September 8, 2026: [native run 34203848028](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34203848028)
passes both iPad and Mac, and [Backend run 34203848023](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34203848023)
passes Python 3.13 and 3.14. The published branch contains workflow commit
`640ae2e` and PR #18 remains open and unmerged. This is evidence for the exact
published transaction checkpoint, not later native composer changes, signed
CloudKit delivery, provider acceptance or production release.

## Bundle review and iPad runtime qualification

The bundle checkpoint adds one selected iPad journey, bringing the total to
**34**, with the complete logic targets retained. It tests the actual original
bundle proposal's component total, expansion, repeated rows and unsent
cancellation/return, not unfinished native bundle selection or editing.
See [bundle transaction qualification](QBO_BUNDLE_TRANSACTION_CONTRACT.md).

Prior head `21694fd` passes [Backend run 34198971037](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34198971037)
on Python 3.13/3.14 and the Mac job in [native run 34198971304](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34198971304).
Its iPad job ended **cancelled**, with GitHub's explicit annotation that the job
exceeded 45 minutes. Logs show continuing successful UI tests before tax-address
review was interrupted. This is not a complete green native qualification.

The updated workflow grants iPad 60 minutes while retaining Mac's 45-minute
limit, every prior selector, the universal Release build, read-only permissions
and artifact retention. No failure assertion or journey is removed. The new
published head still requires its own full hosted result; the final local
1,341 logic tests per platform, five iPad journeys, 546 Backend tests, 42 Tools
tests and universal Mac Release do not substitute for that hosted run.

## Native inventory regression additions

The current native inventory candidate adds two selected iPad journeys, bringing
the total to **33**: offline inventory creation with exact saved price, quantity
and date on reopen, and technician-item correction before administrator approval.
The complete logic target includes inventory/account/scope, identity, receipt
and SQLite migration tests on both platforms. The complete Tools suite covers
the exact additive CloudKit v25 contract. No earlier selector or failure gate
is removed; signing, deployment and production schema promotion are not enabled.

See [native inventory qualification](NATIVE_QBO_INVENTORY.md) for local evidence
and remaining provider, multi-device and full-suite requirements. The published
candidate needs its own exact-head hosted checks; the prior green runs below
do not qualify later changes.

## Latest completed hosted result: `89c6ee7`

[Native run 34193027111](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34193027111)
passes iPad and Mac. [Backend run 34193027148](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34193027148)
passes Python 3.13 and 3.14. Exact-head completion was verified September 8,
2026. This qualifies the server inventory prerequisite and preceding native
catalog receipts, not the later native inventory/v25 changes or production release.

## Earlier completed hosted result: `8aadb75`

[Native run 34188092219](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34188092219)
passes iPad and Mac. [Backend run 34188092174](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34188092174)
passes Python 3.13 and 3.14. Exact-head completion was verified September 8,
2026. This qualifies the initial native shared-history reader, not the later
Item application receipts, CloudKit v24 source contract or production release.

The catalog receipt tests are part of the complete native logic target on both
platforms. The v24 schema tests are part of the unchanged complete Tools suite.
No workflow selector, assertion or failure gate is removed. Local final-source
evidence and remaining full-goal requirements are recorded in
[versioned catalog application](QBO_CATALOG_VERSION_APPLICATION.md).

## Earlier completed hosted result: `29e124d`

[Native run 34184842191](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34184842191)
passes both iPad and Mac. [Backend run 34184842221](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34184842221)
passes Python 3.13 and 3.14. The final exact-head status was verified September 8,
2026. This qualifies the published iPad focus/address/selection checkpoint,
not the later native QBO history changes or a production release.

The new history tests belong to the existing complete logic target on both
platforms; no workflow selector, assertion, or failure gate is removed.
See [native change history](NATIVE_QBO_CHANGE_HISTORY.md) for separate local
evidence and remaining reconciliation, shared-device and provider requirements.

## Earlier completed hosted result: `d804dd6`

[Native run 34180882997](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34180882997)
passes both iPad and Mac. [Backend run 34180882993](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34180882993)
passes Python 3.13 and 3.14. These exact-head results precede the current local
interaction candidate and do not prove that candidate's hosted acceptance.

`IPAD_RECORD_SELECTION_AND_ADDRESS_EDITING.md` records the retained failure
artifacts, direct keyboard-focus reproduction, stable billing-workspace sheet
ownership, full-row selection, and exact-source validation of the new candidate.
No existing workflow selector or failure gate is removed.

## Earlier failed hosted result: `6a0a38e`

[Native run 34178309515](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34178309515)
is terminal, not still running: Mac succeeds; iPad fails.
[Backend run 34178309514](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34178309514)
succeeds on Python 3.13 and 3.14. The completed iPad job is `101912163707`.
Its log reports all 1,271 native logic tests passing, followed by two UI failures:

- `testExistingQuickBooksLinkReviewCancelsAndReturnsToManagement`: line 4330,
  the selected customer switch is `0` instead of `1` after a coordinate tap.
- `testTaxAddressReviewKeepsDraftPricesAndReturnsToBilling`: line 4071,
  the exact-value wait for the initial `Cancelled address` input times out;
  the field still reports the `Street address` placeholder.

These are not the earlier recording's partial `12 Main` snapshot. The log does
not prove whether input missed its target, presentation/focus was incomplete,
or app state reset. The subsequent exact recordings and discriminating focus
reproduction are now retained in `IPAD_RECORD_SELECTION_AND_ADDRESS_EDITING.md`;
no timeout/assertion/selector was weakened and no hosted run was restarted.
This failure predates the backend-only QBO capture checkpoint; native source is
unchanged by that checkpoint.

Read-only retained log:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/QBO Change Capture.r3lvH4/HostedIPad-6a0a38e.log`,
1,148,520 bytes, SHA-256
`ae53eae508d79b0d3d731b96d071ed02b1a763b1a19210713acfc84876d01318`.

## Earlier input synchronization change

The tax-address entry test now waits for the exact completed field value before
continuing. The original hosted recording showed its immediate snapshot racing
unfinished typing; the complete address appeared without another input event.
The same exact-value checks cover reopened fields, with explicit sheet
dismissal/presentation waits after a second recorded transitional snapshot.
All value, cancellation, save, price and reopen assertions remain. See
`TAX_ADDRESS_UI_SYNCHRONIZATION.md` for original evidence and qualification.

The native shared-Mail checkpoint adds two iPad journeys: reading/replying through
the shared transport with natural mailbox/Outbox navigation, and recovering the
original interrupted send after relaunch without another copy. All earlier
selectors and failure gates remain. The new server-Mail, bounded HTTP and
encrypted recovery tests also run with the complete logic target on both platforms.
See `NATIVE_SERVER_MAIL.md` for exact-source local evidence and remaining scope.

The `Native app regression` workflow runs on pull requests, pushes to `main`,
and manual dispatch (available once the workflow is on the default branch).
It complements the existing Backend/Tools Python 3.13 and 3.14 workflow.

## Coverage

The native Google access candidate adds two journeys, bringing the iPad
selection to **twenty-nine**: original approval recovery/cancellation across
relaunch with return to Settings, and exact partial-permission display without
technical details. The final-source local suites pass 1,244 logic tests per
platform and five selected iPad journeys. Backend passes 405 and Tools 37.
Evidence, rollout boundaries and remaining Google feature migration:
[NATIVE_GOOGLE_ACCESS.md](NATIVE_GOOGLE_ACCESS.md). Workflow publication and
exact-head hosted CI are tracked separately; earlier green checks do not prove
the candidate's hosted acceptance.

Preceding head `f082074` passes Backend and Mac, but the hosted iPad
tax-address journey fails before save when its typed street value is incomplete.
Three unchanged local repetitions pass; the cause remains unconfirmed. Preserve
the full-address/save/reopen assertions and require new exact-head hosted checks.
The retained failure and reproduction are detailed in `NATIVE_GOOGLE_ACCESS.md`.

At `cad60f5`, [Native run 34170779743](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34170779743)
passes iPad and Mac, including all 29 selected iPad journeys and the unchanged
tax-address test. [Backend run 34170779787](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34170779787)
passes Python 3.13 and 3.14. This exact-head result does not establish the earlier
tax-input failure's cause or qualify later source changes.

The Mail draft-recovery candidate selects **twenty-seven** iPad journeys.
The three additions verify complete draft/attachment retention across relaunch,
an uncertain send remaining read-only with a handoff to Sent after relaunch,
and autosaved incomplete input surviving termination without closing Compose.
The existing Mail journeys now exercise explicit Save/Delete Draft decisions.
Scope, evidence and remaining cross-device/server gates are recorded in
[GMAIL_DRAFT_RECOVERY.md](GMAIL_DRAFT_RECOVERY.md). Final local acceptance passes
1219 logic tests per platform, ten selected iPad journeys, unsigned universal
Mac Release, Backend 366 and Tools 37. Exact-head hosted checks remain separate.
Preceding head `64e3fce` passes all four hosted jobs:
[Native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34163116116) and
[Backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34163116154).

The preceding billing entry-point checkpoint selected **twenty-four** iPad interface
journeys. The two additions cover cancelling edited Management invoices and
estimates without saving/sending, and saving each original document offline
with return to the same Sales workspace. Both use the real standalone item
builder, not a direct accounting shortcut. The existing Invoice launch journey
also checks the shared service/repair/replacement choice. Final local evidence
and remaining full-suite gates are recorded in
[BILLING_ENTRY_POINT_UNIFICATION.md](BILLING_ENTRY_POINT_UNIFICATION.md).
The new selectors require exact-head hosted qualification after publication.

The preceding native billing publication checkpoint selected **twenty-two** iPad interface
journeys, adding cancellation of an unsent proposal and read-only recovery of
an accepted invoice without publishing again. Final local acceptance passes
1191 logic tests per native platform, four selected iPad journeys (1195 total),
366 Backend tests, 37 Tools tests and the unsigned optimized universal Mac
Release with verified arm64/x86_64 architectures. Six final iPad screenshots
were visually inspected; the account-email footer remains hidden. Scope,
backend-first rollout and evidence are recorded in
[NATIVE_BILLING_PUBLICATION.md](NATIVE_BILLING_PUBLICATION.md).
Published head `2669a4d` passes all four hosted jobs:
[Native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34157688539) and
[Backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34157688652).
These preceding-head green checks do not qualify the entry-point candidate.

Preceding head `9821668` passes all four hosted jobs:
[Native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34153343592) and
[Backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34153343582).
Its workflow `d34b9a8` selects **twenty** iPad interface journeys. It adds
existing-QBO-link cancellation, lost-confirmation GET recovery and cancellation
after reconnection, from source `2c69aa7`. Final local acceptance passes 1174
logic tests per native platform, seven selected iPad journeys, 349 Backend,
37 Tools and the unsigned optimized universal Mac Release. The three final
review screenshots were visually checked. Exact evidence and remaining native
publication/CloudKit/full-goal requirements:
[QBO_EXISTING_LINK_ADOPTION.md](QBO_EXISTING_LINK_ADOPTION.md).
The workflow-only diff adds three selectors, matches the local validated YAML
byte-for-byte and passes actionlint. Current-head hosted checks must complete;
earlier green runs do not qualify this candidate.

Preceding published tax-address head `58470e4` passes all four hosted jobs:
[Native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34149674583) and
[Backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34149674593).
Its workflow `a66dc85` selects **seventeen** iPad interface journeys.
It adds tax-address entry/cancellation, unchanged sold-price confirmation and
saved-invoice reopening on the original job, from source `12ee89a`. Final local
qualification is 1159 logic tests per native platform, five selected iPad UI
journeys and unsigned universal Mac Release. Exact evidence and remaining
native-to-server cutover requirements:
[NATIVE_BILLING_TAX_ADDRESSES.md](NATIVE_BILLING_TAX_ADDRESSES.md).
The workflow-only diff adds one selector and passes actionlint. Its hosted
checks were started; no completed current-head result is inferred from earlier
green checks.

The preceding job-authority candidate added two in-job Field Billing journeys:
saved-crew conflict confirmation with return to the original job, and
read-only recovery of accepted access without another assignment POST.
That preceding workflow selected sixteen iPad interface journeys.
Exact implementation and final local acceptance:
[NATIVE_JOB_BILLING_AUTHORITY.md](NATIVE_JOB_BILLING_AUTHORITY.md).
Published HTTP/client head `12382ae` passes all four hosted jobs:
[Native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34140905031) and
[Backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34140905066).
Those results do not qualify this new candidate or its added journeys.

Published mailbox head `7d18532` now passes all four hosted jobs:
[Native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34127258110) and
[Backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34127258022).
The customer publication candidate adds two customer recovery/cancellation
journeys, for fourteen hosted selections. See
[QBO_SERVER_CUSTOMER_PUBLICATION.md](QBO_SERVER_CUSTOMER_PUBLICATION.md) for
its distinct source/acceptance boundary and the remaining full-goal work.
Previous-head results do not qualify the new candidate.

Published Mail/workflow head `3348725` passes all four hosted jobs:
[Native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34121851059) and
[Backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34121851023).
The mailbox candidate adds older-message/Sent/archive and Trash/restore
journeys, for twelve hosted selections. Its distinct acceptance is documented
in [GMAIL_MAILBOX_WORKFLOW.md](GMAIL_MAILBOX_WORKFLOW.md); previous-head results
do not qualify this new source.
Local mailbox acceptance passes 1081 logic tests per platform and ten selected
iPad journeys, plus Backend 173 and Tools 37. An attempted Mac UI journey
stalled before test startup; it was diagnosed and cancelled, not marked passed
or suppressed in a workflow. The hosted Mac job continues to exercise its
existing logic/Release gate, not Mac UI acceptance.

The published Calendar/documentation head `d9a83d8` passes all four hosted jobs:
[native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34113375386) and
[backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34113375391).
Mail local acceptance passes 1049 logic tests per native platform, eight
selected iPad journeys, Backend 173 and Tools 37, plus the universal Mac Release.
See [GMAIL_COMPOSITION_WORKFLOW.md](GMAIL_COMPOSITION_WORKFLOW.md); these prior
green hosted checks do not qualify the Mail source. The workflow candidate adds
three Mail journeys (retained failed draft, uncertain-send recovery and native
attachment preview/forward/removal) to the seven already hosted, for ten total.

Published shared-catalog head `455ac33` passes all four hosted jobs:
[native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34108280415) and
[backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34108280424).
The subsequent Google Calendar checkpoint has final local acceptance of
998 logic tests on each native platform, seven selected iPad UI journeys,
173 Backend tests, 37 Tools tests and the universal Mac Release build.
See [GOOGLE_CALENDAR_WORKFLOW_LIFECYCLE.md](GOOGLE_CALENDAR_WORKFLOW_LIFECYCLE.md).
It requires its own hosted checks; an earlier green head is not a substitute.

Billing checkpoint `6ded36c` now passes all four exact-head hosted jobs:
[native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34101243455) and
[backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34101243457).
The subsequent server-catalog candidate requires its own hosted acceptance;
see [QBO_SERVER_CATALOG_PUBLICATION.md](QBO_SERVER_CATALOG_PUBLICATION.md).

The catalog checkpoint 705d77e also passes all four hosted jobs:
[native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34097348815) and
[backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34097348890).
Billing local acceptance is recorded in
[QBO_BILLING_WORKFLOW_LIFECYCLE.md](QBO_BILLING_WORKFLOW_LIFECYCLE.md).

The published resource-sync checkpoint 529fe26 passes all four hosted jobs:
[native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34093728868) and
[Backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34093728884).
This is exact-head evidence for that checkpoint, not subsequent catalog work.

- **iPad native tests**: the complete `GunnAire OpsTests` target plus twenty-seven
  serial interface journeys: direct Invoice launch, simple Mail actions,
  current customer statement generation, statement review-to-Invoices,
  billing-identity review-to-Invoices with safe report export controls,
  shared catalog recovery with cancellation of only an unsent proposal,
  exact-target schedule deletion with billed-job retention, editable draft
  recovery after a rejected send, uncertain-send duplicate prevention, and
  native attachment preview/forward/removal, mailbox pagination/Sent/archive,
  recoverable Trash/restore inside the app, and customer sync original-link
  recovery/unsent cancellation with return to the customer record, and
  original job-access recovery and displayed-revision crew confirmation,
  retained tax-address review, and existing-link cancellation, original-decision
  GET recovery and safe cancellation after QuickBooks reconnection, plus native
  billing unsent-proposal cancellation and accepted-invoice read-only recovery
  with return to the original invoice, and Management invoice/estimate unsaved
  cancellation and original-document offline saving with return to Sales;
  persistent Mail drafts/attachments, uncertain-send review-to-Sent after
  relaunch, and autosave recovery after abrupt termination.
- **Mac native tests**: the complete logic target on arm64 Mac Catalyst,
  followed by an unsigned optimized Release build. `lipo -verify_arch`
  requires both arm64 and x86_64 in the Release executable.
- Both test jobs reject failed results and zero passing tests. Logs, summaries,
  and available `.xcresult` bundles are uploaded even after failure and retained
  for seven days. Download them from the run's **Artifacts** section and open
  the result bundle in Xcode.

The workflow selects Xcode 26.6 on the standard arm64 `macos-26` runner.

Workflow commit `b6bf8bf` added catalog recovery to the original five hosted
journeys. Workflow commit `b1ad814` adds schedule deletion protection, making
seven hosted journeys. Its supporting source is `6f56db0`. The hosted selection
differs from the seven focused local calendar-checkpoint journeys documented in
[GOOGLE_CALENDAR_WORKFLOW_LIFECYCLE.md](GOOGLE_CALENDAR_WORKFLOW_LIFECYCLE.md).
Local success does not establish hosted success; inspect the exact PR head's
native and backend checks before approving the candidate.

The iPad destination is the 13-inch M5 simulator on iOS 26.2, matching the
existing local acceptance baseline. These versions were checked against
[GitHub's runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
on September 7, 2026. If that image removes the pinned Xcode or runtime,
the job must fail visibly; review and test an explicit version update rather
than silently changing the acceptance environment.

## Safety and review

This workflow only builds and tests. It has read-only repository permissions,
does not persist checkout credentials, uses commit-pinned checkout/artifact
actions, and does not consume Apple signing or provider secrets. It uses the
existing fixture-based native tests, not a live customer/payment acceptance run.
No provisioning updates, distribution upload, CloudKit promotion, backend
deployment, live charges, or accounting writes are workflow steps.

Do not add `Config/Local.xcconfig`, local authentication state, signing files,
or production credentials to CI. Test artifacts can be visible to repository
readers; retain fixture-only evidence. The shared scheme remains unchanged;
the narrow ignore exception allows shared schemes to be maintained without
including other Xcode shared/user state.

This is not a complete UI, signed-device, production integration, or release
acceptance gate. An open PR is not deployed by this workflow, but **merging to
main can trigger the separately configured Render service**. Do not merge
without the separate production review.

## Validation and maintenance

Before publishing a workflow change, run `actionlint` against both YAML files,
`git diff --check`, and:

```sh
xcodebuild -list -json -project "GunnAire Ops.xcodeproj"
xcodebuild -showdestinations -project "GunnAire Ops.xcodeproj" -scheme "GunnAire Ops"
```

After pushing, inspect the exact commit's checks on the pull request. A local
lint pass or earlier native acceptance result does not establish that the new
hosted workflow passed. Keep both matrix jobs visible when one fails; do not
add `continue-on-error` to hide failures.

The first hosted run at `991b601` failed on QR decoding in the iPad job and
argument ordering in the final Mac `lipo` command. The corrected workflow puts
the input executable before the architecture list. Source QR margin tests and
software rendering address the observed label issue; fresh hosted verification
is still required. See [BILLING_IDENTITY_RECONCILIATION.md](BILLING_IDENTITY_RECONCILIATION.md)
for reproduced failures, local acceptance, and remaining scope.

At `61df19b`, [native run 34088303506](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34088303506)
completed: Mac logic, universal Release and architecture verification passed.
All five iPad UI journeys passed, but the original Vision QR decode assertion
still returned no payload. The hosted log reports that inference compilation
inside the VM supports CPU only. The simulator test now selects supported CPU
devices explicitly using Apple's
[compute-stage API](https://developer.apple.com/documentation/vision/vnrequest/setcomputedevice(_:for:)).
Explicit CPU selection also reproduced an empty result locally. In simulator
tests only, an empty result or the known inference error now falls back to
Core Image's [software QR detector](https://developer.apple.com/documentation/coreimage/cidetectortypeqrcode).
It decodes the actual image; it never returns a supplied expected payload.
Exact payload/customer-match assertions remain, and a blank-image test requires
no decoded value. Native device scanner behavior is unchanged; no test is
skipped. Both hosted failing payloads and the local CPU failing payload are
deterministic software-decoder fixtures. This change requires a fresh hosted
run and does not prove physical camera/Vision scanning.

At `ba5617f`, [native run 34091222075](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34091222075)
passes both iPad and Mac jobs, including the hosted QR regression and universal
Release architecture check. [Backend run 34091222082](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34091222082)
also passes Python 3.13 and 3.14. This is exact-head hosted evidence for the
balance/QR checkpoint, not a blanket qualification of later source changes
or production release readiness.
