# GunnAire signed-device acceptance

This is the final evidence procedure for the current iPad/Mac-first release. It
does not authorize an App Store upload, CloudKit Production promotion, live
QuickBooks mutation, card charge, customer communication, or supplier order.

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
