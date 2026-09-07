# GunnAire signed-device acceptance

This is the final evidence procedure for the current iPad/Mac-first release. It
does not authorize an App Store upload, CloudKit Production promotion, live
QuickBooks mutation, card charge, customer communication, or supplier order.

## Build-2026090506 M5 retained-data and Mac acceptance

The exact Apple Development-signed `1.0 (2026090506)` Release was installed
over `2026090504` on the paired physical 13-inch M5 iPad without removing the
application. The application database identifier remained unchanged, the app
stayed live beyond 60 seconds, and the privacy-minimal mirroring ledger recorded
successful CloudKit setup, import, and export with no failed or running
operation. The app/dSYM UUID is `94140186-7FDB-3EDF-879D-B496AE1D4C5E` and
the arm64 binary SHA-256 is
`77cf16eac5b99997f250d433b25a14a964a11267261015419b7dc9eb1f08ef2e`.

The exact matching hardened-runtime Mac Catalyst archive is universal
`arm64`/`x86_64`, has matching app/dSYM UUIDs
`C998B840-17B8-3BC7-A6C1-B95893A94AE6` and
`CCEE431C-1F38-3841-8603-5DB42E40E201`, and binary SHA-256
`e8b7e8c3423d65527895fb469440376f95ec308966ad7aad7adc1dd4a1f93cf1`.
It remained live for at least 60 seconds, recorded successful CloudKit
setup/import/export with no failed or running operation, and then terminated
normally. Both products retain Sign in with Apple, CloudKit, Associated
Domains, and development APNs. Privacy-safe evidence is
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-05/current-signed-cloudkit-launch-2026090506.json`
(SHA-256
`7a33366242ba5282bf4f1b0c2fde41821eb674a9e00ff603e6aaeb0d414af4c5`).
No normal business store or field value was copied or inspected.

This closes exact-current Development-signed launch and aggregate CloudKit
event health on the primary M5 iPad and Mac. It does not claim Apple
Distribution, App Store upload, Production CloudKit promotion, a controlled
same-record two-device round trip, offline conflict recovery, physical-iPhone
Handoff/Tap-to-Pay, or approved production-provider acceptance.

## Build-2026090417 M5 retained-data acceptance

The exact Apple Development-signed `1.0 (2026090417)` Release was installed
over `2026090416` on the paired physical 13-inch M5 iPad without removing the
application. CoreDevice reported the same application database UUID before and
after installation, proving that the retained application store was preserved.
The installed bundle then completed three terminate-and-launch cycles and
remained live for minimum observation periods of 75, 20, and 20 seconds. The
device's recursive crash-log inventory contains no current-build report; its
newest existing GunnAire report predates this installation.

The retained app and dSYM share UUID
`B09850A5-8B43-33EC-9FE2-08767D8809D5`; the arm64 app binary SHA-256 is
`6834489e1c0ed2d58b996aec537b2455a744a1e2ee41f51e976f3a063e564fd2`.
Strict signature verification passed, and the embedded development entitlements
retain Sign in with Apple, CloudKit `iCloud.com.gunnaire.businesssuite`,
Associated Domains `applinks:gunnaire.com`, and development APNs. The physical
build result reports zero errors, warnings, or analyzer warnings on iPadOS
26.6.1. Privacy-minimal evidence is
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-04/physical-m5-retained-launch-2026090417.json`
(SHA-256
`0312e41822f022cef202286bd1a44b64ddf5b18d07144845e2a4a213cde71b99`).

This closes exact-current-build retained-data installation and launch stability
on the primary M5 iPad. It does not claim a manual two-device Handoff, live
payment/QBO transaction, Production CloudKit promotion, Distribution/TestFlight,
or App Store acceptance.

## Build-2026090416 Command Center CloudKit-hydration recheck

The exact Apple Development-signed `1.0 (2026090416)` Release was installed over
the retained store on GunnAire's physical 13-inch M5 iPad. Its Command Center
uses value-only queue snapshots and excludes temporarily unresolved SwiftData
relationships while CloudKit hydrates, superseding the physical
`2026090413`–`2026090415` crashes. Three independent launches remained alive for
75, 20, and 20 seconds and created no new GunnAire crash report. The retained
database UUID remained `17B8CB0D-EBE8-499F-9400-217DFDB23477`.

The matching app and dSYM share UUID
`7AF08EA6-00B1-31EA-8C78-C5F06172B758`; the app binary SHA-256 is
`949d9b661f89dfd19aa722a5c0f5e7f6d51785a573c14a3c4dfcb36f6df9e89d`.
The embedded entitlements retain Sign in with Apple, CloudKit
`iCloud.com.gunnaire.businesssuite`, `applinks:gunnaire.com`, and development
APNs. Exact current-source simulator acceptance passes **707/707** logic tests
and **112/112 runnable** UI tests with one intentional physical-only skip (113
total, zero failures). The UI result also includes all four successful launch
variants, the simple Inbox/Compose/read/reply/forward/delete Mail contract,
role-only sidebar identity with no email address, and Invoice/Payments crash
regressions. Evidence is retained under `/Users/gunnaire/Downloads/GunnAire Ops
Releases/2026-09-04` as the `2026090416` physical Release app/dSYM/build result,
three device-launch JSON files, complete logic/UI results, and focused privacy,
stability, iPhone, and authorization results.

This proves retained-data install/launch stability for the current Development-
signed candidate. It does not claim Distribution/TestFlight/App Store,
Production CloudKit, backend `.18`, live QuickBooks, supplier, payment, or
customer-communication acceptance. Production CloudKit remains v15 while the
additive v23 contract remains Development-only; the Apple **Deploy** action was
not pressed and no production mutation occurred.

The exact current-source iOS archive and universal Mac Catalyst Release for
`1.0 (2026090412)` are retained under `/Users/gunnaire/Downloads/GunnAire Ops
Releases/2026-09-04`. Both pass strict local signature and app/dSYM validation;
the iOS UUID is `5A4F9978-F4DA-3E01-98B2-A17A08EBC7FF`, and the Mac UUIDs are
`6E7875CC-70C6-37B1-9D6B-A98DDCCA6ECF` and
`87B124A5-C15A-333A-ACB8-5A0896F8D4FF`. The complete current-source Mac
Catalyst logic target passes **706/706**, zero failures or skips. Exact online
preflight is **61 passed / 4 warnings / 1 failure**; the only failure is the
undeployed reviewed backend `.18`, while fresh CloudKit exports and Distribution
signing remain acceptance gates. These new artifacts do not change the physical
iPad result below or authorize upload/deployment.

## Build-2026090412 exact-final-source Invoice recheck

The exact final `2026090412` source was built with automatic Apple Development
signing and exercised against the retained application store on GunnAire's
physical 13-inch M5 iPad running iPadOS 26.6.1. The test passes **1/1** in
**136.703 seconds** with zero failures or skips. It opens Invoices from the
normal signed-in application, completes two Overview/New Invoice round trips,
three Payments/Invoices round trips, and a final 30-second foreground hold.
The app remains alive throughout.

The matching complete 13-inch M5 iPad Simulator interface run passes **111/111
runnable tests**, zero failures, with this physical-only retained-store test
intentionally skipped once. The final physical result is retained as
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-04/Invoice Tab
Isolation 2026090412 Final Source Physical Retained Store.xcresult`; the full
simulator result is `Full iPad UI Regression 2026090412.xcresult`. This is
Development-signed validation and does not claim Distribution/TestFlight/App
Store, Production CloudKit, provider, payment, or customer-communication
acceptance. The exact optimized Release passes strict signature validation with
matching app/dSYM UUID `D66E6C43-F5D1-3A3F-8E47-F3C49EE1D826` and binary
SHA-256 `20fba8b707c78cb4d6e7d97d075a3f7ad50860157feba47f43211de64aa38b56`.
It was installed over the retained app data, launched normally as PID 4641,
and remained alive after the post-install check. The matching app, dSYM, and
build result are retained beside the XCTest evidence. No invoice, payment,
customer, or live QBO record was changed.

## Build-2026090411 Invoice lane isolation recheck

After a user-visible Invoice failure was reported against build `2026090410`,
the connected iPad still showed a live app process and no new GunnAire operating-
system crash report. Build `2026090411` therefore hardens both possible failure
modes: the Overview lane and New Invoice lane now have separate SwiftUI trees,
and the Overview no longer constructs the item selector, item creator, price
adjustment, and document discount presentations during its first render.

Three focused 13-inch M5 iPad Simulator journeys pass **3/3**, including repeated
Payments-to-Invoices navigation and existing-invoice line-item editing. Two
adjacent Overview-owned billing journeys also pass **2/2** for maintenance-
agreement review and exact project-milestone invoicing. The expanded retained-
store test then passed **1/1** on the physical 13-inch M5 iPad
in **135.143 seconds**: two Overview/New Invoice round trips, three
Payments/Invoices round trips, and a final 30-second foreground hold. The exact
optimized Apple Development-signed Release was installed over the retained app
data, launched directly into Invoices, remained live as PID 4553, and produced
no current-build crash report. Strict signature validation passed; the app and
dSYM UUID match (`7FBABA97-C574-3046-93F9-12FAB431CEB3`) and the app binary
SHA-256 is `cb960ecd7c854eb47235a8f85073622d364938daed083ada83750ad35a161c21`.
Evidence is retained in the September 4 release folder as `Invoice Tab Isolation
2026090411 Simulator.xcresult`, `Invoice Tab Isolation 2026090411 Physical
Retained Store.xcresult`, `Invoice Overview Billing Actions 2026090411
Simulator.xcresult`, and the matching Release app/dSYM. No invoice, payment,
provider setting, CloudKit schema, account, or production record was changed.

## Build-2026090405 Invoice sidebar recheck

The retained physical-iPad crash was symbolicated to recursive SwiftUI generic
metadata construction above the standalone Invoice workspace. Build
`2026090405` type-erases the selected split-view detail, preventing a sidebar
transition from constructing all thirteen destination trees at once. The change
does not alter an invoice, QBO payload, role, persistent model, or CloudKit
schema.

Exact verification passes 705/705 Mac Catalyst logic tests and 2/2 focused
13-inch M5 iPad Simulator Invoice journeys. The optimized Apple
Development-signed Release passes strict signature validation and was installed
over the physical M5 iPad's retained application data without deleting the
store. It remained alive for 120 seconds on a forced Invoice route and is open
again in Invoices as PID 4181. The device crash count remains 27; no
build-`2026090405` report exists. Evidence is in the September 4 release folder
as `physical-invoice-sidebar-recheck-2026090405.json` and the associated Invoice
Sidebar Regression, Full Mac Logic, iPad Release Build, and Physical Retained
Store Attempt result bundles.

## Build-2026090404 photo markup and Invoice recheck

Build `2026090404` adds native copy-preserving Markup for job image
attachments. The annotated copy retains applicable customer, job, equipment,
invoice, estimate, agreement, fleet, and expense lineage and enters the
existing offline/company-storage/QBO attachment recovery path. The original
file remains unchanged. Form-row button isolation also prevents Preview,
Annotate, Share, and Remove from triggering together.

Exact verification passes 705/705 Mac Catalyst logic tests and 5/5 critical
13-inch M5 iPad Simulator journeys. The exact optimized Apple
Development-signed Release was installed over the existing physical iPad app
without deleting application data. Its forced Invoice route remained alive as
PID 4170 beyond 152 seconds; the matching crash-log count remained 27 and no
current-build report appeared. Strict signature verification passed, the app
and dSYM share UUID `6423C30F-62CB-3B7A-B3F5-856C9D1EED23`, and the binary
SHA-256 is
`f2c7272e025037255f9a9afc1438aed6dfd3b7a10a547c8e11a1788f886d01f4`.

Privacy-minimal evidence is
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-04/physical-invoice-and-photo-markup-recheck-2026090404.json`
(SHA-256
`721308a82cde7c207ae83567521070a4239918bf3eb155c7d96ff9874916b209`).
This remains Development-signed evidence and does not claim App Store,
Production CloudKit, provider, payment, or customer-communication acceptance.

## Build-2026090403 focused Invoice workspace

Build `2026090403` retains the standalone Invoice root's stack-safe type
boundaries while splitting the long default page into two explicit lanes.
**Overview** contains balances, billing and collections queues, and existing
invoices. **New Invoice** contains customer and line-item creation and cannot
change the document kind away from Invoice. The focused UI regression verifies
both lane contents and process liveness; three adjacent billing journeys and
all 703 Mac business-logic tests pass.

The exact optimized Apple Development-signed Release was installed over the
existing app on the physical 13-inch M5 iPad without deleting application
data. The forced Invoice route remained alive as PID 4163 beyond 150 seconds,
the matching crash-log count remained 27, and no current-build report appeared.
The newest retained application crash remains pre-fix build `2026090301`.
Strict signature verification passed; the app and dSYM share UUID
`93A5162B-5661-3EE5-9B42-DB304DB73B06`, and the app binary SHA-256 is
`54710b3707eb5e1acc133a52c0805870a06a81cfc38662a936f5bd2ebbc883e5`.

Privacy-minimal evidence is
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-04/physical-invoice-focused-workspace-recheck-2026090403.json`
(SHA-256
`ebf5b9bc84f08a5cf3a0e4ba808fe6aa39e05d8da56dd4b97362b5f3b992ca4b`).
No invoice, payment, provider, account, backend, customer communication, or
production record was changed. This remains development-signed evidence, not
App Store distribution acceptance.

## Build-2026090402 Invoice crash correction

The retained build-`2026090301` crash report confirms a main-thread stack-guard
`EXC_BAD_ACCESS` while SwiftUI recursively constructs the generic Billing
`NavigationStack`/`List` type. Build `2026090402` gives the standalone Invoice
tab an invoice-only root and bounds sheet/dialog metadata with small `AnyView`
groups; job Billing keeps its full workflow behind separate boundaries. A
temporarily unresolved invoice-customer relationship is retained for CloudKit
recovery but is not force-rendered as a row.

The exact optimized Apple Development-signed Release was installed over the
existing `com.gunnaire.businesssuite` app on the physical iPad Pro 13-inch
(M5) without deleting application data. The Invoice route remained alive
through an attached diagnostic and then under a second normal launch for more
than 45 minutes. The device produced no September 4 GunnAire crash report; its
newest retained application crash remains the pre-fix build `2026090301`
report from September 3. The complete simulator regression passes every
runnable logical test; the only skipped case is the explicitly gated
retained-store physical automation, whose route was exercised separately on
the real iPad because Xcode timed out enabling physical UI automation.

Privacy-minimal evidence is
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-04/physical-invoice-stack-safe-recheck-2026090402.json`
(SHA-256
`d9ea09ae262ead8c2a3eddbe7d417eb053db65317c52d9cf00e0eb4362fce958`).
No invoice, payment, provider, account, backend, customer communication, or
production record was changed by this validation. This is development-signed
device evidence, not App Store distribution acceptance.

## Build-2026090401 controlled online continuity

The exact current signed Debug products completed an isolated CloudKit
Development Mac Catalyst → physical 13-inch M5 iPad → Mac → iPad
create/update/delete round trip. The Mac created one fixed noncustomer canary;
the iPad observed it and changed it; the Mac observed the change and deleted
it; and the iPad observed zero remaining matches. Every phase reported build
`2026090401`, schema version `2`, the expected state and count, and a satisfied
expectation within the bounded retry window. The remote canary was deleted and
both devices were purged to zero local probe files. The exact signed Release
was then restored to the iPad without deleting application data. A second
read-only inspection on September 4 verified the retained store contains 154
invoices with no missing or dangling customer relationship, reinstalled the
same signed Release, and opened the Invoice route against that live store. The
process remained foregrounded beyond 105 seconds and the device produced no
current-build crash report; the newest retained Invoice crash remains the
pre-fix build `2026090301` SwiftUI metadata-stack failure.

The privacy-minimal live-store recheck is
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-04/physical-invoice-live-store-recheck-2026090401.json`
(SHA-256
`1b91dc082d88d175a6e3f19c8ad964953a49b6104511aad92ca4c4117e875111`).

Privacy-minimal evidence is
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-04/ipad-mac-cloudkit-roundtrip-2026090401.json`
(SHA-256
`ba8def0fed99fbe3ebf834703de6b29239950b1dc094f88f45299833745b2812`).
The signed Debug build results are retained beside it. This proves exact-source
online Development continuity only. It does not prove the human-observed
two-device offline same-record conflict sequence below and does not authorize
or claim Production CloudKit promotion.

## Build-2026090201 offline-conflict acceptance procedure

Build `1.0 (2026090111)` introduced the version-2 Debug-only acceptance probe
for the outstanding two-device offline same-record conflict and recovery gate;
the exact current build `1.0 (2026090201)` retains it. The implementation and
its local state-machine coverage pass, but the signed physical sequence below
has **not** run. The paired iPad was unavailable at the latest local check after
iPadOS previously denied launch while it was locked. Exact build-`2026090201`
generic iOS and arm64 Mac Catalyst Debug products now build, pass strict
signature inspection, contain the probe, and are retained beside the Release
archives, but the iOS product has not been installed on the iPad. Do not
convert this section to passed evidence until every step completes on the exact
signed Mac and iPad builds and the redacted reports agree.

The exact development-signed build-`2026090201` Release archives and
verification manifest are retained under `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-02`.
Both archives pass strict artifact validation and exact local preflight, but
they are not Distribution-signed and do not replace
the Debug products required for the conflict probe. The retained build-`2026090111`
readiness/template remain historical and must not be relabeled as current-build
physical evidence. The incomplete acceptance template correctly remains failed
closed until its 19 physical/provider scenarios have real evidence.

The current source passes **693/693** logic tests on both iPad Simulator and Mac
Catalyst. The latest complete iPad UI baseline remains build `2026090111` at
**103/103** logical tests with **106/106** device executions. These are local
implementation/regression evidence only; they do not substitute for the
physical offline/reconnect sequence.

Execute the sequence in this order in CloudKit Development:

1. Unlock the iPad and keep it awake. Install the exact iOS Debug build
   `2026090201` on the iPad and use the exact Mac Catalyst Debug product on the
   Mac. Both must be signed by the same development team and use
   `iCloud.com.gunnaire.businesssuite`.
2. Launch `-purgeLocalCloudKitRoundTripProbe` once on each device. This removes
   only the version-2 probe store/support/assets/report on that device; it does
   not delete the remote canary or open the normal business store.
3. With both devices online, launch `-seedCloudKitConflictCanary` on the Mac,
   then `-observeCloudKitConflictSeed` on the iPad. Require state `original`
   and match count `1` on both reports.
4. Take both devices offline using their normal network controls. Do not infer
   offline state from a launch result. Launch `-writeCloudKitConflictA` on the
   Mac and `-writeCloudKitConflictB` on the iPad. Require `conflictA` and
   `conflictB`, respectively, each with match count `2`.
5. Reconnect both devices. Launch `-observeCloudKitConflictConverged` on each
   until both independently report `conflictConverged`, match count `3`. This
   is the required proof that both immutable A/B witnesses arrived even though
   CloudKit may select either A or B for the shared task value.
6. On one device that already reported convergence, launch
   `-resolveCloudKitConflictCanary`. Require `conflictResolved`, match count
   `4`. On the other device launch `-observeCloudKitConflictResolved` and
   require the same state and count.
7. On the resolving device only after count `4`, launch
   `-cleanupCloudKitConflictCanary`. Require `absent`, count `0`. On the other
   device launch `-observeCloudKitConflictDeleted` and require `absent`, count
   `0` after the bounded observation window.
8. Launch `-purgeLocalCloudKitRoundTripProbe` on both devices. Confirm that no
   version-2 store, support, asset, or report file remains locally. Retain only
   a new privacy-redacted summary of mode, state, count, build, attempts, and
   timestamps; do not retain account, device, customer, invoice, payment, or
   business-note values.

After every phase from seed through deleted observation, capture the report
before launching the next phase because the app replaces the prior report. Use
the fixed phase identifiers printed by `--help`; this command validates the
exact build/mode/state/count and writes a privacy-minimal file without the raw
error text, source path, device identifier, or account identity:

```sh
python3 Tools/cloudkit_conflict_acceptance.py \
  --capture mac-seed \
  --report "/path/to/GunnAireCloudKitRoundTripProbeV2.json" \
  --evidence-directory "/path/to/new-conflict-evidence-directory"
```

Use the same new evidence directory for all ten phases, then require the full
ordered set to pass:

```sh
python3 Tools/cloudkit_conflict_acceptance.py \
  --validate-directory "/path/to/new-conflict-evidence-directory"
```

The collector refuses to overwrite a retained phase. Its sequence validation
does not prove that network controls were off during the two write phases;
record that operator-observed condition separately in the signed-device
acceptance record.

Any `unexpected`, `duplicate`, or `error` state; missing witness; count drift;
timeout; wrong build; or residual remote/local marker is a failed or blocked
acceptance, never a pass. The procedure follows Apple's
[local-store synchronization](https://developer.apple.com/documentation/coredata/synchronizing-a-local-store-to-the-cloud)
and [conflict-resolution](https://developer.apple.com/documentation/coredata/conflict-resolution)
guidance reviewed read-only in Safari.
It authorizes no Production CloudKit promotion or account-console change.

## Build-2026090110 controlled evidence

Build `1.0 (2026090110)` is retained as development-signed iOS and universal
Mac Catalyst archives and is installed on the paired iPad Pro 13-inch (M5),
iPadOS `26.6.1`. Its current privacy-minimal readiness files are:

- `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/physical-device-readiness-connected-2026090110.json`
  (`SHA-256 fa79146c25bcb063a4c0d3baf8eca89be8913ccfc7d41af07741765e849946ef`)
- `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/physical-device-acceptance-2026090110.json`
  (`SHA-256 32111eeead132420a6fca79e21f687f4be3e56901323e11b21dc4bdbe0dc489f`)
- `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/ipad-mac-cloudkit-roundtrip-2026090110.json`
  (`SHA-256 9310fb532666b60f89b6bc4999d9031331f7fa01e4fa2fbfe248540aa9e190bb`)

The signed CloudKit Development sequence passed in this exact order: Mac
created one isolated fixed-ID noncustomer canary; iPad observed the original;
iPad updated it; Mac observed the update; Mac deleted it; and iPad observed it
absent. A separate iPad baseline proved the marker was absent before creation.
The Debug-only probe used its own temporary store, never opened the normal
business store, is compiled out of Release, and left zero local support, asset,
report, or store files on either device. The retained JSON contains no emails,
device identifiers, customer names, addresses, invoice amounts, payment data,
or business notes. This proves exact two-device create/update/delete propagation
in Development; it does not prove offline reconnect, conflict recovery,
Production promotion, authentication, or iPhone Handoff.

A retained exact build-`2026090109` physical-iPad Release crash was symbolicated
with its matching dSYM to recursive Swift generic metadata instantiation in
`BillingDocumentsView.body` immediately below `NavigationStack`, ending in a
stack-guard `SIGSEGV`. Build `2026090110` erases that oversized root generic
boundary. The optimized signed Release build, focused simulator admin launch,
and technician invoice-item/update journey pass. The complete iPad UI target
also passes **103/103 logical tests** with **106/106 device executions**, zero
failures or skips, and build `2026090110` is installed. The final unlocked
physical normal-launch/no-new-crash check is still
pending because iPadOS currently reports the device locked. Do not treat the
simulator or successful install as physical Release launch acceptance.

The readiness report remains not-ready overall because the Apple Distribution
and separate Mac distribution private keys are not installed and no paired
iPhone is available. No browser or account console was used for this work; the
Safari-only instruction was honored.

## Prepared build-2026090109 package

The privacy-minimal readiness report and incomplete acceptance template are
already retained at:

- `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/physical-device-readiness-connected-2026090109.json`
  (`SHA-256 4d05bbce662b256f792a947b017d8e40a8edde4b040f7d37a321b0d6ee880288`)
- `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/physical-device-acceptance-2026090109.json`
  (`SHA-256 a7f39db62715ea000b02e6bd325d2ccd0e90cdc6c1805e239b001a157c7884f9`)
- `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/mac-cloudkit-launch-2026090109.json`
  (`SHA-256 18128932e0481e063f8596814833fe59960e91d9887dbc8e2bc08fb789a584ae`)
- `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/ipad-mac-cloudkit-convergence-2026090109.json`
  (`SHA-256 059612fc6d088de3589aea6ae18dc43095be829b8fe87f4867f837db11996731`)
- `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/GunnAire Ops 1.0 (2026090109) Mac Sign-In no-email.jpeg`
  (`SHA-256 3d03fdb60e10627d4a1325402c1a134454a94b550c0a5b9ecfbad20aade1a2f5`)

The readiness report records only aggregate signing counts and a hashed device
reference. The paired iPad Pro 13-inch (M5) now passes tunnel, Developer Mode,
DDI, and signed-device readiness, and exact build `2026090109` is installed and
running. The current blockers are the missing iOS and Mac distribution private
keys and no paired iPhone. The template contains all 19 required scenarios with
`not_run` status and no workflow evidence. Its validator correctly reports 47
incomplete requirements until a real operator, timestamps, device models, OS
versions, passing statuses, and privacy-safe evidence references are supplied.
Do not recreate or overwrite these files; complete the retained template during
the signed-device session.

The current universal Mac archive has also completed a privacy-safe signed-out
launch. The visible screen contained Google and Apple sign-in controls and no
account email. Its Development CloudKit ledger recorded successful setup,
import, and a zero-object export, with no running operation or failure after the
launch. This proves exact-build Mac receipt from the Development container; it
does not prove authentication, record authorship, a two-device mutation round
trip, offline recovery, conflict handling, or Production readiness.

The installed exact iPad build independently recorded successful Development
CloudKit setup, import, and export immediately after the Mac receive cycle, with
no pending import/export or current warning. Its event ledger retains seven
older `CKErrorDomain` export failures and the later successes that recovered
them instead of erasing that history. A temporary read-only snapshot compared
only row counts for all 32 SwiftData entity tables; the iPad and imported Mac
count vectors matched exactly at SHA-256
`f8050397a35a0dca5d677738e385cae1a5908687ea926bf3671f7fc4e22dfa49`.
No business field value was inspected, and the temporary preferences and store
copies were removed. This proves aggregate record-graph convergence, not
field-by-field equality or a controlled bidirectional create/update/delete.

## 1. Inspect readiness

Run the privacy-minimal, read-only inspection from the repository root:

```sh
python3 Tools/physical_device_acceptance.py \
  --archive "/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/GunnAire Ops 1.0 (2026090109 Current Source).xcarchive" \
  --mac-app "/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/GunnAire Ops 1.0 (2026090109 Current Source Mac Catalyst).xcarchive/Products/Applications/GunnAire Ops.app"
```

The inspection reports only a hashed device reference, model name, OS,
pairing/tunnel state, Developer Mode, and DDI readiness. It deliberately omits
serial numbers, UDIDs, ECIDs, account identities, customer data, and provider
credentials. It does not install or launch the app.

For a machine-readable report, supply a new path with `--json-output`. The tool
refuses to overwrite existing evidence. Add `--require-ready` only when the
iPad, iPhone, iOS distribution identity, and Mac distribution identity should
all be available; otherwise blockers are reported without treating the
inspection itself as a technical failure.

## 2. Create the exact-build record

The exact current template already exists. For a later build, create one new
template at a unique path; never overwrite retained evidence:

```sh
python3 Tools/physical_device_acceptance.py \
  --create-record "/Users/gunnaire/Downloads/GunnAire Ops Releases/YYYY-MM-DD/physical-device-acceptance-BUILD.json"
```

Keep `qboEnvironment` as `sandbox` for pre-release acceptance. A Production QBO
record cannot validate without an explicit production-mutation authorization
reference. Likewise, Production CloudKit evidence requires a recorded promotion
approval reference. Never put customer names, addresses, emails, card data,
OAuth credentials, tokens, device identifiers, or private field notes in the
record or its screenshots/logs.

## 3. Execute the required scenarios

Use current build `1.0 (2026090109)` on the signed iPad, iPhone, and universal
Mac app. For every scenario in the generated record, retain at least one
privacy-safe evidence reference and record `passed`, `failed`, or `blocked`.
Required coverage includes:

- fresh Apple login, role resolution, revocation, and every access level;
- uncluttered iPad/Mac navigation, attached-keyboard commands, Dynamic Type,
  VoiceOver, Reduce Motion across launch and common tasks, dispatch conflicts,
  and auditable overrides;
- complete offline Service, Repair, and Replacement work: findings, forms,
  photos/files, parts, labor, customer approval, closeout, reconnect, and file
  regeneration;
- two-device CloudKit create/update/delete, offline relaunch/reconnect, conflict,
  account loss, reassignment, and fail-closed recovery;
- iPad-to-iPhone and Mac-to-iPhone payment Handoff, delayed invoice sync,
  30-minute expiry, sign-out/revocation, and invoice-UUID-only payload privacy;
- QBO sandbox technician-created item review, exact invoice-line create/update,
  SyncToken handling, tax/discount/quantity parity, lost-response recovery, and
  proof that one stable local marker creates at most one provider record;
- the supported QuickBooks Mobile/GoPayment route for success, decline,
  interruption, partial state, and accounting reconciliation without treating
  a redirect as payment success;
- Google business sign-in, Gmail, Calendar, and duplicate-safe Drive archive;
- APNs assignment delivery/tap/logout/token-revocation behavior;
- physical equipment barcode/QR scanning and printed asset-label round trip;
- logout, device-loss, credential revocation, local-data protection, and removal
  of stale notification/Handoff access.

The payment scenarios validate GunnAire's supported handoff and reconciliation
boundary. They do not claim an embedded ProximityReader implementation. Embedded
Tap to Pay remains gated on an Apple-supported PSP, its SDK and merchant terms,
Apple's managed entitlement, certification, and a compatible physical iPhone.

## 4. Validate the record

After all scenarios have real evidence and the operator/timestamps/device models
are recorded, run:

```sh
python3 Tools/physical_device_acceptance.py \
  --validate-record "/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/physical-device-acceptance-2026090109.json"
```

The validator fails closed for a stale build, missing device summary, missing or
duplicate scenario, anything other than `passed`, missing evidence,
future/invalid timestamps, evidence flagged as containing customer/payment data,
or Production QBO/CloudKit evidence without the appropriate authorization.

Only after this record passes should the reviewed CloudKit v22 delta be promoted
to Production. Re-export Production, run the exact release preflight, require
Development/Production parity, create fresh distribution-signed iOS and Mac
artifacts, and perform the separately authorized TestFlight/App Store steps.
