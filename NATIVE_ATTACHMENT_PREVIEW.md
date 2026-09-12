# Native attachment preview qualification

## Observed defect

PR18 parent `223f1b4`, native run `34398474947`, iPad job `102624128999`
failed `testMailAttachmentPreviewAndForwardRetainTheOriginalFile` at its
content assertion. The retained xcresult reports 1,863 cases: 1,862 pass, one
failure, no skips. Video and accessibility evidence show a genuinely blank
Quick Look sheet with its title and Done button visible. The original file
contains 24 bytes of UTF-8 text. Neither premature file removal nor repeated
controller updates has been established as the underlying cause.

The unchanged journey passed on a warm simulator and a new M5/iOS 26.2 simulator.
These local passes do not resolve the hosted failure. Evidence remains under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Mail Preview CI.tZN0aD`.

## Candidate

Read-only plain-text attachments use a native, selectable, dynamically sized
reader instead of the remote Quick Look renderer. The bounded asynchronous
reader retains whitespace and Unicode, supports explicit UTF-8/16/32 byte-order
marks, and does not guess invalid encodings. Files over the 2 MiB native-reader
bound and non-text/unknown formats retain Quick Look; this is not an import or
attachment-size limit. Empty files and read failures are distinct, with close,
share-original and retry actions appropriate to their state. Stale/cancelled
reads cannot replace a newer file or restore dismissed content.

Editable-copy requests retain Quick Look, including the existing annotation
callback. Unchanged SwiftUI updates do not reload its data source. A separate
Reload Preview action invokes Apple's current-item refresh method; this is
recovery support, not a claim that the underlying renderer defect is resolved.
Original Mail temporary-file protection, ownership, cleanup, and forwarding are
unchanged. Synthetic PDF/PNG files are confined to the existing DEBUG UI fixture.

Apple distinguishes [data-source reload](https://developer.apple.com/documentation/quicklook/qlpreviewcontroller/reloaddata())
from [current-item refresh](https://developer.apple.com/documentation/quicklook/qlpreviewcontroller/refreshcurrentpreviewitem()).
The focused preview returns to the original message, consistent with the
[sheet guidance](https://developer.apple.com/design/human-interface-guidelines/sheets).
These pages were checked in Safari on September 9, 2026.

## Verification and retained failures

The original failing UI test is unchanged. First candidate `MacFocused1` has
31 passing cases and one failed encoding test; `IPadFocused1` has 34 passes and
the same failure, including all three passing UI journeys. Foundation silently
accepted two malformed Unicode inputs as empty text. The correction requires
an exact byte round trip before selecting the native reader. Bounded reads also
combine short chunks through EOF instead of accepting an incomplete first read.
The original assertion is retained; no malformed-byte expectation is weakened.

Final frozen source (`OriginalPreflight2`) passes:

- `MacFocused2`: 34 cases, both requested suites verified.
- `IPadFocused2`: 37 cases, both suites and all three UI journeys verified.
- `MacFull1`: all 1,858 logic cases; three target/suite identities verified.
- `IPadFull1`: 1,865 cases, ten requested target/suite/journey identities verified.
  This is the complete logic target plus seven UI journeys: original text preview,
  PDF preview, image preview, invoice workspace, simple Mail, retained attachment
  draft/relaunch, and customer account statement preview.
- `Tools1`: all 74 tests; both workflow files pass `actionlint` and `git diff --check`.
- `Backend1`: all 852 tests, 127.663 seconds; local fixtures, not live-provider acceptance.
- `DeviceRelease1`: unsigned arm64 iOS Release build/architecture verification;
  SHA-256 `37c49008d84fc2329d3fdb37789dbd5ed26509c9c11fbaa6dfd7838fb3bbab15`.
- `MacRelease1`: unsigned universal Mac Catalyst Release build and arm64/x86_64
  architecture verification; SHA-256
  `8f62b51f57b57eda4553e9f62baab3ff6e2490ce0d1dc16f7b7dc18de8de5e21`.

All passing native results above have zero failures and zero skips, checked from
the actual xcresult test tree, not a discovery list. Commands and unique result
paths are retained by `/tmp/gunnaire-workflow-validation.NYZ8uS/qualify_mail_preview.sh`.
They use Xcode 26.6 (17F113), scheme `GunnAire Ops`, unsigned Debug tests,
nonparallel execution, arm64 Mac Catalyst and the dedicated 13-inch M5 simulator
`0ADE5A1A-9859-4377-AD5E-93FC6D70F1D3` on iOS 26.2. No existing simulator was erased.

Six final-run iPad frames were inspected: text/PDF/image preview, original forward,
inbox and compose. Original content is visible, native controls are readable,
and no account-email footer appears. These fixtures do not prove every real-world
format, annotation gesture, Dynamic Type size, VoiceOver path, or Mac layout.
The new PDF/image journeys are locally qualified but are not yet added to the
hosted workflow's explicit UI selectors; the existing text journey and all logic
tests remain selected there.

`MacUI1` is a retained failure, not a skipped or passing acceptance gate. macOS
displayed a damaged-runner launch alert. Read-only signature verification reported
missing resources required by the generated runner's signature. The UI tool was
instructed to press the observed Cancel button, never Move to Trash. Its response
and subsequent alert readbacks timed out; terminal process/result evidence then
confirmed that the runner ended with exit 65 and “hung before establishing
connection.” Its result has zero passing UI tests and one
runner failure. No file was removed or security/signing setting changed. A properly
signed test harness is required before retrying Mac UI acceptance; repeating the
same unsigned launch is not useful qualification.

Both Release builds are terminal successes. Copy-back verifies all eight scoped
files byte-equal, preserves 391 unrelated owner changes and the owner's original
branch, HEAD and empty index. OriginalPreflight2 also checked 397 other tracked
sources against the review checkout. Only the isolated review branch is committed.
Final proof is retained in OriginalCopyBack2.json beside the test evidence. Existing
QuickBooks actor-isolation warnings are retained; this preview change does not
resolve them. PR18 parent `d65fed9` has passing Backend and Mac hosted checks while
both iPad groups remain live as of 21:52 UTC. No successor push interrupts them.
Fresh exact-head hosted acceptance remains required after publication.

No merge, deployment, signing, provider write, CloudKit schema change, or physical
device install occurs here. Full CloudKit/staff/domain/role/store/command/media
convergence, live provider/payment/vendor acceptance, device Handoff and broad
accessibility remain required. The complete application goal remains active.
