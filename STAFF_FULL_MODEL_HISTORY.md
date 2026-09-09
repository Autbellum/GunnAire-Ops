# Full owner-model history and encrypted preparation

2026-09-09 — candidate built on `a0fd766`. This is an essential data-preservation
stage toward the complete independent-account CloudKit workspace, not a claim
that staff delivery, all business features, or the full application are complete.

## Observed gap and correction

The full owner catalog already represented all 32 SwiftData model types, but
only six model IDs were retained in deletion history. The unchanged original
two-test reproduction failed on the other 26 attributes and on invoice/payment
tombstones after reopening an actual SQLite store. Existing six-kind source
publication cannot carry the rest of the domain.

All 32 original UUID attributes now use `preserveValueOnDeletion`. The catalog
provides a typed deletion reader using each existing codec's original ID key
path, so there is no second manually maintained type switch. Unknown deletion
types and missing original IDs stop capture; absence alone is never a deletion.

Apple documents chronological history, opaque Codable tokens, and retaining
stable identifiers explicitly for deletion recovery. The implementation follows
that model and does not inspect opaque token internals. See Apple's
[SwiftData history guidance](https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes).

`StaffWorkspaceHistory` verifies the physical single on-disk store even when
history is empty, exact schema/model coverage, the previous transaction/token
anchor, bounded chronological history and the complete typed relationship graph.
A final history fence rejects a mixed snapshot if another context/process saves
during the read. A missing/expired/foreign cursor does not advance. Unsaved main
context work stays untouched. Recreating an original ID produces a live record
without automatically authorizing restoration of a server tombstone.

## Connected lifecycle and authority boundaries

The existing foreground owner sync lifecycle now stages all 32 model types
before capturing newer core facts. It still recovers the exact original pending
six-kind operation first. Full preparation failure prevents a newer publication
without losing that pending request or its confirmed recovery.

The full journal uses a separate `StaffWorkspaceOwner-v1` directory, local
Keychain encryption key and authenticated scope containing company, backend,
actor, CloudKit environment/replica/account and owner store identity. AES-GCM
and atomic writes preserve snapshot, original deletion keys and cursor together.
Access is checked before reading and again before writing. An unreadable,
future-field, mismatched or invalid journal is not reset to an empty success.
Unacknowledged deletion keys survive relaunch and unchanged captures. Only a
currently live record with that exact original ID removes its local deletion key.

This is owner-only staging: it can contain private HR, cost and financial fields.
It is never sent as a raw staff payload, used as an access grant, or written to
the existing `core-field-v1` server ledger. Staff lease/import activation remains
closed until full-domain, role-safe delivery is complete. The original content
bytes for attachments still require their own authenticated media pipeline;
owner-local file paths are not transferred by these codecs.

## Evidence and reproduction

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Full Staff History.9UR2Kn`

- `Reproduction1.xcresult`: two failing tests, three issues, before production
  edits. Invoice and payment deletion entries existed but original IDs were nil.
- `Focused1` and `Focused2`: test compilation failures from throwing Swift Testing
  macro expressions. These runs are not credited as executed behavioral tests.
- `Focused3.xcresult`: 42 actual passing cases; all four requested suite identities
  verified from the xcresult test tree, with zero failures/skips. Includes the
  original two reproductions without weakened assertions.
- The migration test copies all generated persisted attributes/relationships
  into an actual prior-schema SQLite store with only the original six history
  flags. Reopening with the current model preserves all 32 original records,
  their encoded values, owning relationships, local attachment path and store
  UUID. A subsequent payment deletion retains the original payment ID.
- A separate legacy-deletion test proves already-lost IDs require review rather
  than inventing IDs or discarding history. No production history is deleted.
- Additional tests cover empty/partial/in-memory/wrong stores; foreign, malformed,
  future-version, reduced-coverage and expired cursors; cross-context saves;
  unsaved edits; recreation with the same original ID; encrypted restart recovery;
  denied scope, failed writes, malformed journals and core pending-operation order.
- `Tools1.log`: all 74 tooling tests pass.
- Expanded tests add a first-save/empty-history race and verify that restoring
  one original record retains the other 31 deletion keys. `MacFull1` and
  `IPadFull1` pass 1,874 and 1,879 actual cases. Both first Release builds pass,
  but expose a new actor-conversion warning in the history reader. The final
  source explicitly types that reader `@MainActor` and resolves a test-only
  optional-value macro warning without weakening migration assertions.
- `MacFull2` verifies all 1,874 actual cases and five selectors; `IPadFull2`
  verifies 1,879 cases and ten selectors, including all five UI journeys.
  Both have zero failures/skips. Their authoritative test trees retain all ten
  history tests, including the original invoice/payment reproduction.
- `DeviceRelease2` passes the unsigned arm64 iOS Release build and architecture
  check. SHA-256: `55b72f68b15773a14ccac06dd53a141db5dfb0ab9c34be1594b3c919e1e3afb7`.
  `MacRelease2` also passes unsigned Release and both arm64/x86_64 architecture
  checks. SHA-256: `f3d06431cd1f0b7d12e87758b17164c12e5d05ca1ce9ebbb308d2a767f33c6a5`.
- Existing QuickBooks actor-isolation warnings remain in the unchanged QBO
  sources. The new history-reader and migration-test warnings are absent from
  final test logs and both final Release logs. The existing missing Metal
  toolchain linker search-path warning also remains on Mac. These results are
  not a claim of a warning-free whole application. All local runs are terminal.

Commands use Xcode 26.6, the existing `GunnAire Ops` scheme and
`CODE_SIGNING_ALLOWED=NO`. Mac tests target arm64 Mac Catalyst. iPad tests use
the dedicated M5 iOS 26.2 simulator
`0ADE5A1A-9859-4377-AD5E-93FC6D70F1D3`. The frozen-source helper is
`/tmp/gunnaire-workflow-validation.NYZ8uS/qualify_full_history.sh`; modes include
`MacFull`, `IPadFull`, `MacRelease`, and `DeviceRelease`. The xcresult verifier
checks that requested tests actually ran, not merely that a build succeeded.

## iPad interface review

Six first-run and four final-run screenshots were inspected. Final screenshots
are in `IPadFinalUI2` with a manifest mapping them to actual executed tests.
The inbox/compose screens are readable, without raw transport data or the
account-email footer. The invoice editor preserves the edited bundle and original
amount. Staff receipt status still explicitly says full data is required before
opening; receipt of six record kinds does not bypass the workspace gate.

Review used Apple's [sidebar guidance](https://developer.apple.com/design/human-interface-guidelines/sidebars)
for understandable selection, grouping and navigation. Remaining observed polish
work is recorded rather than declared complete: the invoice editor's expanded
costing content is dense, and an accepted staff request still exposes acceptance
controls below its confirmation. Compact-window behavior, sidebar customization,
dynamic type, screen-reader use and full Mac visual acceptance remain unverified.
The prior unsigned Mac UI-runner signature failure is not retried unchanged.

`OriginalPreflight2.json` freezes 30 scoped files, verifies 379 other tracked
sources match the owner's checkout, and protects 385 unrelated local changes
plus the original branch, HEAD and empty index. `OriginalCopyBack2.json`
verifies all 30 files byte-equal after copy-back, all 385 unrelated changes
preserved, and original branch/HEAD/index unchanged. Only the isolated review
checkout is committed; the owner checkout remains on its original branch.

## Limits and remaining full-goal work

Capture is bounded at 20,000 records/32 MiB and 100,000 history transactions or
deletion identities. Oversized or incomplete work requires review; it is not
silently truncated. Large-store performance, paged full-domain reconciliation,
historical missing-ID resolution and a coordinated history retention policy
still require implementation/qualification. This code never purges history.

The separate full-domain server schema/revisions, remaining nested financial and
workflow validation, explicit role projections, full staff store import/lease,
field commands/conflicts, original media and independent-account signed-device
CloudKit convergence remain incomplete. Existing local tests do not prove live
provider/vendor/QBO/payment or iPad-to-iPhone Tap-to-Pay acceptance. Broad iPad/Mac
navigation, accessibility and competitor-feature completion remain full-goal
requirements. No entitlement/signing/schema promotion, physical install, provider
mutation, deployment or main merge is performed by this checkpoint.

The prior Mail checkpoint `a0fd766` was pushed to PR18 only after parent
`d65fed9` Backend/Mac/both iPad CI jobs were verified terminal and successful.
The exact-head native run `34411588111` remains live at final local qualification;
Backend `34411588114` passes both Python versions. This history checkpoint stays
local while that predecessor is live, so a push does not cancel its checks.
Those parent-head runs do not qualify this history candidate.
