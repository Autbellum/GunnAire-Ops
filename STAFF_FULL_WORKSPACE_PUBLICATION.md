# Full owner workspace publication — candidate

Status: locally qualified source candidate, copied into the original project. This is not a claim that
the full application, staff CloudKit convergence, or production deployment is
complete.

## Scope and integration

The native app previously retained all 32 model kinds locally but only uploaded
the six-kind staff source. The new owner publisher connects the existing
`/api/workspace/full-records` contract, `owner-workspace-v1`, with its pinned
561-field schema digest. The endpoint is a separate encrypted administrator-only
server copy. It does not import records into the live owner SwiftData store,
grant staff permissions, expose HR/financial fields through the core projection,
publish QBO transactions, or activate a partial staff workspace.

The existing core coordinator first recovers any original in-flight six-kind
operation. It then recovers the original full-workspace operation before reading
new owner history. Full history remains encrypted with its original store cursor
and deletion IDs. Once full publication is quiescent, the existing core capture,
publication and staff-delivery preparation continue.

## Recovery and reconciliation

- Store the exact original POST bytes, stable operation UUID and original remote
  fingerprints durably before any network submission. Relaunch, timeout, lost
  receipt, cancellation, malformed acknowledgement or failed local save cannot
  silently replace or discard that operation.
- Only the backend's explicit `source_changed`, `record_changed` and
  `deletion_changed` rejections prove no mutation. Retain those requests in the
  encrypted rejected-operation archive before starting a fresh reconciliation.
  Unknown errors, schema changes and replica changes retain the pending original.
- Validate scope at storage, transport, response and approval boundaries:
  business actor, backend origin, company, environment, replica, CloudKit account,
  physical store identity and current verified session. A process-local mutation
  gate also prevents competing publisher instances replacing an in-flight queue.
- Decode exact envelope/tag fields, reject duplicate keys including escaped
  aliases, validate the pinned catalog and every typed record, and bound bytes,
  nesting, node count, pages, revisions and operations. Original typed JSON string
  values remain opaque here; the server copy is not financial/domain approval.
- Fence every page and the end of a scan against one server sequence. Actual-wire
  size may produce short pages. A scoped in-memory cache is rechecked with a
  sequence-fenced first page before reuse, and invalidated after errors/session
  changes or an acknowledgement that observes a newer writer.
- Publish at most eight bounded batches per foreground pass; recapture and fence
  again before subsequent work. A missing local record never invents a deletion.
  Retained server tombstones require exact owner approval before restoration.
- Three-way comparison uses small exact-content fingerprints. Remote-only edits
  wait for the original company CloudKit records to arrive. Divergent saved
  versions require an approval bound to both exact versions; newer edits require
  review again. The server copy is never blindly imported into the owner store.

## User-facing review

Settings → Staff Data Preparation → Review Company Workspace keeps the review
away from ordinary jobs, Mail and invoices. Differences are disclosed on demand;
serialized payloads are described rather than displayed as code. Confirm/cancel
applies only the reviewed complete saved record or saved deletion to the owner
server copy. It does not change the live iCloud record or QBO.

The contextual status and explicit confirmation follow Apple's
[Alerts guidance](https://developer.apple.com/design/human-interface-guidelines/alerts).
No automatic informational alert is added. This design has not yet passed
interactive navigation, VoiceOver, Dynamic Type or visual acceptance.

## Evidence and user privacy constraint

Local evidence root:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Full Owner Publication.x0kUmj`.

- `MacFocused1`: candidate build failed on a throwing expression inside a Swift
  Testing assertion. Fixed the assertion and a new method-reference actor warning;
  neither failed compilation nor this correction is counted as a test pass.
- `MacFocused2`: intentionally stopped before test execution to honor the user's
  new requirement not to change their visible desktop. This was not a timeout,
  flaky-test retry, or accepted qualification result.
- The user requires background-only work and no screenshots, screen recording,
  screen inspection or browser switching. No further CUA or screen-capture tools
  are used. Qualification uses background compilation and headless iPad unit
  tests; no UI-test or capture selectors are included.
- `IPadFocused1`: compilation exposed a throwing assertion hidden inside a
  macro in a fixture closure. The journal read is now explicitly outside the
  assertion so the closure's throwing behavior is inferred correctly.
- `BackendSource1`: all 29 existing full-source backend contract and HTTP tests
  pass.
- `IPadFocused2`: 51 passing cases, zero failures/skips, and all four requested
  suite selectors verified from the actual xcresult test tree. Includes the
  actual backend-page decoder with all 32 record kinds and 561 fields, exact
  retry bytes, failed pending/acknowledgement saves, six rejection categories,
  short-page/end fences, 805-record bounded publication, concurrent instances,
  absence-versus-deletion, exact approval/restore, access revocation and saved
  SQLite deletion. UI handoff tests exercise coordinator state transitions and
  readable presentation values, not screen interaction or a physical relaunch.
- `IPadFull1`: 1,895 passing unit-test cases, zero failures/skips, complete logic
  target plus all four required suite selectors verified. Xcode 26.6 (17F113),
  iOS 26.2, 13-inch M5 iPad simulator
  `0ADE5A1A-9859-4377-AD5E-93FC6D70F1D3`. No UI tests/capture selectors.
- `Tools1`: all 75 tests pass.
- `MacRelease1` and `DeviceRelease1`: both initial unsigned builds and architecture
  checks pass (universal arm64/x86_64 Mac and arm64 iOS). Hashes are retained in
  the evidence root. These precede the performance correction below and are not
  final-candidate Release qualification. Existing four QBO actor warnings and the
  Mac Metal-toolchain search-path warning remain; none is suppressed.
- The 805-record focused test took 14.339 seconds. Inspection identifies repeated
  reconstruction of all 32 typed codecs/561-field metadata in per-record key and
  record validation. The publisher now holds immutable validation metadata once;
  company records, sessions and journals are not held in that metadata cache.
  The same full validation and original-boundary tests must pass unchanged.
  This is a measured fixture concern, not proof of real-device UI responsiveness.
- Added an actual encrypted-on-disk publication journal test: missing keys must
  leave the sealed original untouched, and new store/publisher instances must
  recover the identical request without a second operation.
- `IPadFocused3`: the same four suites now verify 52 passing cases with zero
  failures/skips, including the new encrypted-file recovery test. The unchanged
  805-record test completes in 1.199 seconds versus 14.339 seconds previously
  (about 12 times faster in this fixture). No company data, authorization result
  or response is cached in the immutable codec lookup. Larger real-world data,
  memory pressure and UI frame-time qualification remain open.
- Final `IPadFull2`, `MacRelease2` and `DeviceRelease2` are running on the
  metadata-reuse candidate. OriginalPreflight2 freezes its nine source/test paths
  plus two evidence documents, with 419 unrelated owner changes preserved and
  410 other tracked sources matched. No original copyback has happened yet.
- `IPadFull2` completes with 1,896 unit cases, zero failures/skips and all five
  required selectors. Review then identifies an additional handoff timing case:
  a new saved owner edit can arrive during a server read, between full capture
  and subsequent core capture. A regression is required before this checkpoint
  can claim a quiescent full-source handoff. Current release invocations remain
  unchanged until terminal; this finding is not silently counted as covered by
  the earlier pass.
- `MacRelease2` and `DeviceRelease2` both finish successfully, including the
  architecture checks. They precede the handoff correction and are retained as
  intermediate builds, not final qualification for that correction.
- `HandoffReproduction1` confirms the gap against unchanged app code: 52 cases
  pass and the new timing test fails. Core capture starts while the full owner
  snapshot is already outdated. The correction returns the prepared stage to
  the core caller and verifies fresh durable owner history synchronously before
  core capture, with no intervening suspension. A mismatch requests another
  full-source pass; it neither discards the edit nor publishes newer core facts
  ahead of the full original. The reproduction's assertions remain unchanged.
- `IPadFocused4` verifies all 53 cases and four suite selectors, including the
  unchanged timing regression. The new handoff case passes in 0.045 seconds.
  Final full-unit and unsigned Release checks are running on this correction;
  OriginalPreflight3 is the current frozen-source/copyback baseline.
- Final `IPadFull3` verifies 1,897 unit cases with zero failures/skips and all five
  target/suite selectors. Final `MacRelease3` and `DeviceRelease3` both pass,
  including universal arm64/x86_64 Mac and arm64 iOS architecture verification.
  Final executable SHA-256 values:
  - Mac: `96b72028e41120e8a8cc72dc21e440747324c77488f06bbaeeedb000adc3c4b7`
  - iOS: `ab792a85efc19e746f328bce31586a959b9967ed1f2e3bf9e03cddff8fbc54e3`
  The four pre-existing QBO actor warnings and the Mac linker search-path warning
  remain. No new warning suppression, signing or provisioning changes were made.
  Every local build/test process is terminal before source copyback.
- `OriginalCopyBack1` verifies all 11 scoped files byte-equal between the review
  checkout and original project, with 419 unrelated changes and the owner's
  branch, HEAD and index preserved. Only the isolated review checkout is
  committed. Visual acceptance, full Mac runtime tests and production promotion
  remain separate gates; no screen inspection or recording is used.

## Remaining gates

Full Mac unit qualification, complete owner-review interactions,
independent-account signed CloudKit convergence, role-safe full-model projections,
staff-store imports/activation/leases, field-command reconciliation and original
media delivery remain incomplete. The prior snapshot/graph bounds (20,000 live
native records / 32 MiB) and server historical bounds (100,000 retained records /
64 MiB encrypted source) require volume/performance qualification. The bounded
rejection archive requires a coordinated retention/recovery policy at capacity;
it is never silently pruned.

The matching backend endpoint must be deployed and verified before enabling this
candidate in production; an older backend does not receive an unsafe fallback
payload or a fabricated staff-delivery success. No production or accounting
mutation is authorized by this checkpoint.

GitHub PR 18 still points to `e8545c2`. Both predecessor workflows passed, but
publishing the earlier local `cf551b3` workflow update was rejected because the
saved PAT lacks `workflow` scope. Permission expansion is awaiting user approval.
No attempt to bypass that permission, merge, deploy, or change signing was made.

## Skill-guided verification

API and access-control guidance kept the full-owner schema separate and enforced
scope at every boundary. Offline-sync guidance required original durable request
bytes and recoverable failures. Xcode and troubleshooting guidance required an
unchanged failing reproduction before the handoff correction, followed by actual
test execution. Interface guidance kept version review secondary and omitted raw
structured payloads. Reliability guidance preserved live builds and the owner's
branch, index and unrelated edits. The live lifecycle/reference audit is at
`/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`.
