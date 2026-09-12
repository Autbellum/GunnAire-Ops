# Full staff CloudKit integration — local candidate, not release acceptance

The full application goal remains ACTIVE. This slice combines the full32 owner
CloudKit seal/publication, independent participant key/receive path, operational
mount/read adapters, media grants and recorded field-command path present in the
parallel working tree, then closes reproduced recovery and authorization gaps.
It is not a claim of physical independent-account acceptance or complete staff
workflows. A recorded field command is not yet an applied owner-record mutation.

## Isolation and ownership

Development remains background-only: no screen recording, capture, inspection,
browser interaction, desktop switching, foreground app launch or UI tests.
The shared review checkout continued receiving parallel UI/handoff changes.
Validation therefore uses the frozen snapshot `f3684e1` at
`/Users/gunnaire/.codex/worktrees/StaffCloudValidation.fKeZms/checkout`, plus the
explicit recovery corrections. Later shared-checkout UI changes are not included
in these test claims and will not be overwritten or silently staged.

The qualified slice is to be committed separately with parent `70b1686`, excluding
the private validation snapshot and generated Python caches. Protected owner
copy-back covers 52 text files; its preflight preserves 447 unrelated changes,
the owner branch/HEAD/index and 433 other tracked source files. Final copy/commit
proofs are retained alongside the qualification results, not inferred from intent.

## Changes and sibling-pattern sweep

- Owner content gets one immutable server-held encrypted seal key/nonce and a
  digest marker in the same database transaction. Missing or corrupt committed
  material cannot regenerate a replacement. Staff receives keys only after current
  account, share, role, company, replica and source checks; CloudKit contains the
  encrypted asset and key-free manifest, not the key or readable business payload.
- Native owner publication now checks server authority around CloudKit operations.
  Participant cached-remount, convergence and readiness paths also check current
  server authority; an old local marker never substitutes for an authorization check.
- Full and core replica manifests reject duplicate JSON keys. Both exact-upload
  retry paths recheck the current head and original asset. Full participant download
  rechecks the head after opening its asset. Lost replies do not overwrite newer heads.
- Seal receipt validation requires the entire original content receipt, including
  freshness, coverage, schemas and readiness flags, with bounded size arithmetic.
- A successor local mount uses a selection-specific immutable payload slot before
  switching metadata. The original v1 payload remains readable and retained. Every
  before/after-write interruption is tested; mismatched existing bytes are not erased.
- Pending command indexes retain complete original requests before per-command
  writes, making interrupted enqueues discoverable across a new process. Legacy
  indexes are read strictly; dangling or conflicting entries fail explicitly.
  Existing command receipts cannot be replaced by a different acknowledgement.
- Server command bodies and receipts are encrypted at rest. Replay is bound to
  the original actor, original request and exact stored receipt/row identity.
  Encryption failure leaves no partial command. Corrupt originals are retained.
  Plaintext rows from the unreleased draft are not silently accepted or rewritten.

CloudKit writes retain atomic, change-tag-checked saves and verify returned records,
consistent with [Apple's modifyRecords contract](https://developer.apple.com/documentation/cloudkit/ckdatabase/modifyrecords(saving:deleting:savepolicy:atomically:)).

## Evidence

Evidence directory: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Full Cloud Integration.8CDRUd`.

- `BackendFocused1`: 75 passed. Initial complete backend runs passed 1,007 tests
  each on Python 3.9.6 and 3.12.14 before the additional command-storage corrections.
- `NativeFocused1`: 40 tests/four selectors passed on the frozen combined snapshot.
- `NativeFocused2`: retained failing reproductions for stale cached authorization,
  partial mount replacement, lost command-index writes and receipt-field substitution.
- `NativeFocused3`: 83 tests/nine selectors passed after the corrections.
- `NativeFull1`: 2,020 passed/two failed. Both failures were old assertions expecting
  the previous payload location to be overwritten; updated assertions verify the
  new active mount and retained original bytes. Production code was unchanged.
- `NativeFull2`: 2,022 tests passed, zero failures/skips, exit 0. Nine selectors are
  independently verified, including full/core CloudKit recovery and operational gates.
- `Tools1`: 75 passed, exit 0. `CommandBoundaryRed1` retains the server journal
  encryption/actor/receipt failures; `CommandBoundaryGreen1` passes 11 tests.
- `MacRelease1` and `DeviceRelease1` pass unsigned Release compilation and architecture
  checks (Mac Catalyst arm64+x86_64; iOS arm64), exit 0. Binary SHA-256:
  Mac `2655204ccc134146d8bba3928cefbc26bda1c56bfba0a536fc94e8ae4ed96eaa`;
  iOS `c2ab08584e4b78ff51c6caa2bfdd7c5aeef2a528aab10fc10aa89343c26ee9a8`.
  QBO actor warnings remain, along with actor-default-argument warnings in the
  parallel operational host/store adapters, an unused presentation binding and the
  Mac toolchain search-path warning. These are tracked debt, not suppressed or
  represented as warning-free builds. No physical app/device acceptance is claimed.
- `BackendFull2` passes 1,011 tests on Python 3.9.6 in 207.143 seconds;
  `BackendPython3122` passes 1,011 tests on Python 3.12.14 in 205.547 seconds.
  Both exit 0, including encryption-failure atomicity. All qualification process
  handles are closed. Final source hashes remain bound to `OriginalPreflight4.json`.

## Still required before release

Independent signed Apple accounts/devices must exercise full32 CloudKit schema,
sharing, revocation, mount convergence and recovery. The local readiness journal
and mocked CloudKit tests are not that physical acceptance evidence. Finish actual
staff command application/reconciliation, complete forms/equipment/billing edit
workflows and media ownership/integrity/resource-limit acceptance. Inspect the
iPad/Mac UI for simplicity, accessibility and natural navigation when screen/UI
testing is permitted. Integrate and requalify the later parallel UI/handoff changes.
Live QBO invoice/document/time/item, Google/vendor/payment acceptance and physical
iPad-to-iPhone Tap-to-Pay remain required. Hosted CI, push permission and deployment
are separate gates; no push, merge, signing or live provider writes occurred here.

API/access-control guidance drove fresh authorization and exact replay identities;
offline/reliability guidance drove immutable payload slots and write-ahead commands.
Swift/troubleshooting guidance required actual failing reproductions and the full
native regression. Audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`.
