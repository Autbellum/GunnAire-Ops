# GunnAire signed-device acceptance

This is the final evidence procedure for the current iPad/Mac-first release. It
does not authorize an App Store upload, CloudKit Production promotion, live
QuickBooks mutation, card charge, customer communication, or supplier order.

## 1. Inspect readiness

Run the privacy-minimal, read-only inspection from the repository root:

```sh
python3 Tools/physical_device_acceptance.py \
  --archive "/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-30/GunnAire Ops 1.0 (2026083101 Current Source).xcarchive" \
  --mac-app "/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-30/GunnAire Ops 1.0 (2026083101 Current Source Mac Catalyst).app"
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

Create one new template in the retained Verification folder:

```sh
python3 Tools/physical_device_acceptance.py \
  --create-record "/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-30/Verification/physical-device-acceptance-2026083101.json"
```

Keep `qboEnvironment` as `sandbox` for pre-release acceptance. A Production QBO
record cannot validate without an explicit production-mutation authorization
reference. Likewise, Production CloudKit evidence requires a recorded promotion
approval reference. Never put customer names, addresses, emails, card data,
OAuth credentials, tokens, device identifiers, or private field notes in the
record or its screenshots/logs.

## 3. Execute the required scenarios

Use current build `1.0 (2026083101)` on the signed iPad, iPhone, and universal
Mac app. For every scenario in the generated record, retain at least one
privacy-safe evidence reference and record `passed`, `failed`, or `blocked`.
Required coverage includes:

- fresh Apple login, role resolution, revocation, and every access level;
- uncluttered iPad/Mac navigation, attached-keyboard commands, Dynamic Type,
  VoiceOver, dispatch conflicts, and auditable overrides;
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
  --validate-record "/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-30/Verification/physical-device-acceptance-2026083101.json"
```

The validator fails closed for a stale build, missing device summary, missing or
duplicate scenario, anything other than `passed`, missing evidence,
future/invalid timestamps, evidence flagged as containing customer/payment data,
or Production QBO/CloudKit evidence without the appropriate authorization.

Only after this record passes should the reviewed CloudKit v22 delta be promoted
to Production. Re-export Production, run the exact release preflight, require
Development/Production parity, create fresh distribution-signed iOS and Mac
artifacts, and perform the separately authorized TestFlight/App Store steps.
