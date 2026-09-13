# Automatic staff CloudKit delivery

Candidate implementation — 2026-09-09. This is a transport milestone, not proof
that staff can yet open a complete operational workspace on independent accounts.

## Connected workflow

The existing authorized-owner foreground/save/CloudKit lifecycle now runs the
automatic publisher after a complete saved-source reconciliation. A source write
requires a fresh capture and source read on the next pass before delivery. Pending
source requests, conflicts, incomplete batches, or missing owner records do not
qualify as a completed source snapshot.

For each accepted and currently eligible staff share, the app first checks whether
another owner device already delivered the exact source revision. Adoption verifies
the actual CloudKit head, original encrypted CKAsset, authenticated payload bytes,
current server authorization, and a second head read. A matching head alone is not
delivery proof. Equal-revision competing operations never overwrite one another.

When preparation is needed, an encrypted per-store/per-member journal persists the
exact operation ID, body and original share plan before its first POST. Recovery
replays that original before preparing newer work. A documented transactional
`source_changed` rejection proves nonapplication; unknown failures retain the
pending original. Superseded immutable receipts are archived before replacement.
Finalized operations use separate immutable archive files, avoiding an unbounded
in-memory history array. Archive/index write interruptions remain recoverable.

The publisher uses the existing atomic private-share asset/head transfer with an
additional current-source requirement on every metadata authorization. All nested
server, CloudKit and journal boundaries retain the physical owner-store and business
session fence. Role, membership, company, account, invitation and assignment checks
remain separate from encryption integrity and Apple's share permissions.

One member's network or invitation failure does not suppress other eligible
members. Revoked or unaccepted shares are never automatically reapproved. No
sealing key, plaintext customer record, provider token or password is placed in
the automatic publisher's journals or CloudKit manifest fields.

## Interface

Settings > Users > Staff Data Preparation remains a secondary detail screen.
A standard transient progress indicator explains ongoing sync without adding
transport metadata to mail, jobs or invoices. The result distinguishes records
shared through iCloud from confirmed receipt on a staff device. The existing iPad
administrator journey exercises saved-change comparison, Cancel, exact approval,
the follow-up check, and return navigation using a synthetic transport only.

## Provider guidance

Reviewed in Safari on 2026-09-09:

- [Apple CKAsset documentation](https://developer.apple.com/documentation/cloudkit/ckasset):
  assets accompany fetched records but their staging URLs are temporary; the
  existing bounded immediate asset read remains mandatory for adoption.
- [Apple progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators):
  show transient progress for lengthy synchronization, keep descriptions concise,
  and do not make users initiate every normal refresh.

## Qualification

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Automatic Staff Delivery.K9qX9f`.

`MacFocused1` stopped at a new test's argument-type compilation error; the
production preparation policy compiled. The test was corrected to pass the byte
count expected by the existing setup-route checker, without removing its assertion.
`MacFocused2` then verified all 60 requested preparation/delivery/source cases.
Five additional automatic-delivery cases were added before final qualification.

Final-source results, all terminal success:

- `MacFull1.xcresult`: 1,699 verified cases, including all 21 automatic-delivery
  cases and the complete native app logic target; zero failures or skipped cases.
- `IPadFull1.xcresult`: 1,703 verified cases on the iOS 26.2 M5 13-inch iPad
  simulator: the complete logic target plus staff administrator/source comparison,
  participant relaunch recovery, invoice opening and shared-mail navigation.
- `IPadInventory1.xcresult`: three more existing UI journeys replayed in hosted
  order, with parallel testing disabled: time-worker mapping, locked progress
  invoice creation, and offline inventory creation/reopening. All pass in 160.155
  test seconds; inventory itself takes 73.503 seconds. No animation-idle warnings
  occur in this local replay. Assertions and workflow timeouts remain unchanged.
- `BackendFull1.log`: all 852 tests pass. `BackendContract1.log`: all 52 focused
  source/projection/encrypted-transport tests pass. No backend code changed.
- `Tools1.log`: all 69 tests pass; both workflows pass actionlint and diff checks.
- `MacRelease1.log`: unsigned universal arm64/x86_64 Release build succeeds.
  Both architectures verified; SHA-256
  `0acc7ec6ec02c810f564c274129cd5eff84eab9c2ba4d40fe7937e86d8e29549`.
- `DeviceRelease1.log`: unsigned arm64 iOS Release build succeeds; architecture
  verified; SHA-256
  `7564131b0996c244c34b75910d82473d29d8d13bb96e71f7d9118fb076af3530`.

Actual execution is checked using `Tools/verify_native_test_execution.py` against
the retained summary/test-tree JSON, not only a green xcodebuild banner. Three
current screenshots were visually inspected: saved staff comparison
`ReviewAttachments/E845271B-63AA-4317-AB19-D5BBBAC3B696.png`, original invitation
`ReviewAttachments/30F99C91-6811-41A2-AE8D-3869371F287B.png`, and simple Inbox
`MailAttachments/A2EEF9F9-EBF5-421B-A2D6-3C612B685AE6.png`. There is no account-email
footer. Invitation and message participant addresses remain appropriate content.

Copy-back preflight `OriginalPreflight2.json` scopes 13 files, preserves 327
unrelated changes, and verifies 348 other tracked sources match. Final copy-back
verification confirms all 13 files match and the original Xcode branch, HEAD,
index and all 327 unrelated changes are preserved.

Published predecessor e8cf7e8: both hosted backend jobs, Mac and iPad shard 2 pass.
iPad shard 1 is terminal canceled after its approximately 60-minute job window;
the native aggregate is canceled, not green. Read-only exact-job diagnostics show
repeated 60-second animation-idle waits during inventory editing, not a recorded
assertion failure. The same ordered journeys pass locally as described above;
this does not establish the cause of the hosted-only behavior or prove it fixed.
It was not canceled or restarted by this task. New candidate hosted acceptance
remains required.

## Remaining full-goal requirements

Staff snapshot import, isolated operational-store activation, complete domain
serialization beyond the six core-field kinds, offline field-edit reconciliation,
and signed independent-account convergence are still required. Current transport
tests do not prove those requirements, QBO production publication, Tap to Pay
provider acceptance, physical-device handoff, or full competitor feature parity.
No live CloudKit/provider/customer writes, schema promotion, production deployment,
signing changes, physical install, or merge is included in this candidate.
