# Owner saved-change preparation

Candidate: 2026-09-09. This is one stage of the independent-account CloudKit
pipeline, **not full staff workspace convergence or production acceptance**.

## Implemented path

The authorized `CompanyWorkspaceHost` attaches `StaffReplicaSourceRecoveryModifier`.
An active owner administrator prepares changes at startup/foreground, after saved
model changes (750 ms debounce), after completed successful CloudKit events, and
on a bounded foreground recovery interval. Only the verified owner private store
can reach the source HTTP endpoint. Staff metadata exceptions are not broadened.
Application sessions, actual signed CloudKit environment/account, backend company
binding, store registration, physical SQLite UUID and access generation are checked.
Test databases cannot execute the live path.

`StaffReplicaSourceHistory` captures saved customer, property, equipment, technician,
job and catalog facts using the existing `core-field-v1` serializer. Stable UUIDs
on these six models now use Apple's `preserveValueOnDeletion` metadata. Chronological
SwiftData transactions supply deletion evidence, including after a process restart.
The history boundary is checked again after the model fetch. Unsaved work, changed
history, missing tombstone IDs, expired/unreadable history and a different store do
not advance a successful checkpoint. No history is purged by production code.
The existing models, IDs and relationships are not replaced by source preparation.

## Recovery and conflict rules

The encrypted device-only recovery journal is scoped to backend origin, business,
environment, replica, owner CloudKit account, administrator and actual store UUID.
It keeps the captured source and cursor together, explicit deletions, acknowledged
record baselines, exact pending operation, explicit rejected originals and reviewed
comparisons. A replaced store cannot inherit the old store's cursor or pending write.

Before the first POST, the exact operation ID, expected source sequence, record
revisions, action and body are saved. A lost reply or failed local receipt save
replays that same request before capturing newer changes. Only a validated exact
receipt advances the acknowledged baseline. A known transactional rejection is
retained in the journal before a subsequent reconciliation may create a new operation.
Unknown errors or conflicting operation identity cannot discard the original request.

Source reads use consistent sequence-bound pages and an end-of-read sequence fence.
The comparison does not assume that obtaining the newest sequence grants overwrite
permission:

| Saved device state | Shared source state | Result |
|---|---|---|
| Matches shared live record | Same facts, possibly newer revision | Adopt matching baseline; no POST |
| Changed since acknowledged baseline | Exact baseline unchanged remotely | Publish saved edit with revision checks |
| Unchanged locally | Changed remotely | Wait for owner CloudKit hydration; no partial-schema import |
| Changed locally | Changed remotely / no known common baseline | Preserve both; show comparison |
| Missing locally without deletion history | Present remotely | Wait; never infer deletion |
| Explicit saved deletion | Exact acknowledged remote baseline | Publish retained tombstone |
| Live locally | Deleted remotely | Never silently restore; review is required |

Settings > Users > Staff Data Preparation shows concise status and a secondary
comparison screen. Only differing fields are displayed. Cancel sends no decision.
An administrator may approve the exact saved version or recorded deletion; both
local and remote values are checked again. A changed comparison requires review
again. Approval affects the staff source ledger, not QBO or the owner SwiftData
store. No unsolicited error dialog or account-email screenshot footer is added.

## Limits and failure behavior

- At most 100 changes and 1 MiB per selected native batch; continuation is automatic.
- Complete source scans stop without truncating above 20,000 records or 64 MiB.
- History scans stop without advancing above 100,000 transactions.
- Encrypted journals are bounded at 64 MiB; storage failures retain the prior file.
- Up to 1,000 explicitly rejected originals are retained before recovery review is
  required. Pending/unknown requests never become successful due to a retry limit.
- HTTP replies are bounded during receipt, do not use caches/cookies and never follow
  redirects. Only known 409 source/revision/deletion rejection codes permit archiving.
- No new credentials, app entitlement, signing setting, CloudKit schema promotion,
  live provider write, production deployment or physical-device install is included.

## Verification

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Owner Source Sync.ZONgQP`.

Focused Mac checkpoint `MacFocused5.xcresult` passes the source recovery/conflict,
on-disk history/migration and bounded HTTP suites. Earlier fixture failures remain
in the evidence directory: Swift test-macro syntax, an invalid JSON-decoded Schema
fixture losing custom enum registration, and a shared-metadata fixture that did
not actually isolate the legacy schema. The corrected migration test copies the
generated Core Data model and removes only the six history-preservation flags.
It reopens a real SQLite store under the current schema and checks original customer
ID, consent, property relationship, SQLite UUID and current metadata. A separate
disk test deletes all six kinds, reopens, verifies exact tombstone UUIDs, then resumes
from the retained token without replaying prior deletions. No assertions were removed.

Final local qualification:

- `MacFull3.xcresult`: 1,675 executed native cases, zero failures/skips. Summary
  and actual test tree verified for the complete target and both new source suites.
- `IPadFull1.xcresult`: 1,679 executed cases on M5 13-inch/iOS 26.2: the complete
  logic target plus staff request recovery, administrator invitation/source review,
  invoice navigation and shared mail. All five selectors verified, zero failures/skips.
- `BackendFull1.log`: all 852 tests pass; the narrower source/transport suite also
  passes all 52 cases. Backend implementation/version is unchanged by this patch.
- `Tools1.log`: all 69 pass; both existing workflows pass actionlint and diff checks.
- `MacRelease1.log`: unsigned universal arm64/x86_64 Release succeeds; both actual
  binary architectures verified. SHA256:
  `20a53204f0defee9ba8e1c26bf481b7c60418a8f3a136025ce01d34a46f69c22`.
- `DeviceRelease1.log`: unsigned arm64 iOS Release succeeds; architecture verified.
  SHA256: `0f55bf5c49a694d6cf3ed0d9926f63325b5fc9ab995121b5bcd58751372c82c5`.
- Three current iPad screenshots inspected: differing saved/shared address, original
  invitation, and simple Inbox. No account-email footer or raw payload is shown.

The existing administrator CloudKit journey verifies entering the comparison from
Settings, canceling without a write, approving the exact version and returning.
The first iPad run showed that a confirmation popover omitted its Cancel action;
the production view now uses a standard confirmation alert with an explicit Cancel
button. The original assertions then passed. The workflow's existing selector covers
these extended steps without token-scope or workflow-permission changes.

`OriginalPreflight2.json` freezes 22 scoped files and verifies 337 other tracked
sources match. Completed copy-back verifies all 22 files equal and preserves the
original branch/HEAD/index and all 315 unrelated changes. Hosted e8cf7e8 backend and Mac jobs passed; its two iPad jobs
were still active at this local checkpoint. Publishing a successor must not cancel
that still-running run. No new-source hosted success is claimed here.

## Remaining end-to-end work

This source coordinator does **not yet automatically prepare per-member projections
and call the separately implemented encrypted CloudKit delivery coordinator**.
Independently registered staff-store import/application, complete business-domain
serializers, durable technician command reconciliation, signed independent-account
acceptance and complete suite/device qualification remain required. A source receipt
does not unlock the owner's private store for a different iCloud account. Billing,
forms, media, agreements, time and tasks remain outside this core-field serializer.
The full business application goal remains active.

## Primary references checked in Safari and installed SDK

- [Apple: Fetching and filtering time-based model changes](https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes)
- [Apple: Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)
- Installed Xcode 26.6 SwiftData interface: `HistoryDescriptor`,
  `DefaultHistoryTransaction`, `DefaultHistoryDelete`, `HistoryTombstone`,
  `DefaultHistoryToken`, `ModelContext.didSave` and attribute options.

The iOS/iPadOS deployment target remains 26.0; the scheme, dependencies, production
store gate and signing configuration are unchanged.
