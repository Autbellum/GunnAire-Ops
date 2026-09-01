# GunnAire signed-device acceptance

This is the final evidence procedure for the current iPad/Mac-first release. It
does not authorize an App Store upload, CloudKit Production promotion, live
QuickBooks mutation, card charge, customer communication, or supplier order.

## Prepared build-2026090109 package

The privacy-minimal readiness report and incomplete acceptance template are
already retained at:

- `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/physical-device-readiness-connected-2026090109.json`
  (`SHA-256 4d05bbce662b256f792a947b017d8e40a8edde4b040f7d37a321b0d6ee880288`)
- `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/physical-device-acceptance-2026090109.json`
  (`SHA-256 a7f39db62715ea000b02e6bd325d2ccd0e90cdc6c1805e239b001a157c7884f9`)
- `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-01/mac-cloudkit-launch-2026090109.json`
  (`SHA-256 18128932e0481e063f8596814833fe59960e91d9887dbc8e2bc08fb789a584ae`)
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
