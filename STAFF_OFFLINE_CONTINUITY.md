# Staff connection-loss continuity — 2026-09-11

## Implementation and boundaries

A positively identified connection failure now retains the already-opened, verified staff workspace and its navigation/editor state. No disk-only snapshot is opened through this fallback. The same current business session, account-generation fence, accepted plan, role, device identity and original session expiry still apply. Unknown errors, access denial, missing/invalid snapshots, recovery/storage problems, TLS failures, cancellation and CloudKit permission/partial failures do not permit fallback. Remote revocation cannot be discovered while disconnected; once observed it closes access, and offline mode never extends the existing session deadline.

Both setup and replica transport sanitizers preserve a typed offline error without exposing raw provider details. Classification recognizes a small allowlist of URLSession/CFNetwork connection errors and CloudKit network failures, validates nested causes to a bounded depth, and refuses mixed partial failures. The setup path compares freshly observed account, role/binding and each invitation page with the current presentation before another network operation can conceal a change. Setup and receive now share the same in-flight guard.

The staff workspace gets a contextual “Showing saved records” banner and Retry action only during an outage. A successful, fully verified retry clears it. Session-deadline, significant-clock-change and foreground checks close expired presentations. This does not introduce a new top-level destination, app AI endpoint, owner-store bypass, or provider mutation.

Existing durable draft and original-operation rules remain in force. A partially received successor may leave the last fully opened records visible, but the current mounted-head checks prevent submitting an old field revision. Existing input can still be saved locally under its original draft ID; reconnect requires explicit review against changed office data. An unverified save is not represented as durable. Offline state is in-process only: cold start, sign-out, account change and scene inactivity do not reopen data through this fallback.

## Evidence and qualification

Baseline: `84598f8d7544b0c82aa4a9e5d21270274aea08e1`. The regression `testNetworkFailureRetainsVerifiedHostAndOriginalEditorDraft` ran against the unchanged app implementation. A synthetic URLSession connection-loss error at the real receive-to-open boundary cleared the host, editor draft and displayed text. `Red1.xcresult` records one executed test with four failing assertions; xcodebuild exited 65.

Evidence directory: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Offline Continuity.wkvEoV`.

- Initial focused native run: 63 passed, no failures/skips; five requested selectors independently verified from xcresult.
- Final focused native run: **67 passed**, no failures/skips; all six requested selectors verified from xcresult, including the 15 new tests.
- Full native logic suite: **2,225 passed**, no failures/skips; all six affected selectors independently verified from xcresult. No UI test suite was executed.
- Universal unsigned Mac Catalyst Release: **passed**, `x86_64 arm64`, build `2026090506`. Existing missing Metal-toolchain linker search-path warnings remain. Native compilation also reports redundant `#require` warnings in unchanged tests; none were suppressed.
- Tools: 75 passed, no inference, `/Users/gunnaire/Documents/GunnAireLocalQA/runs/tools-0q7ss7vy/report.json`.
- Local Ollama assistance: `gunnaire-coder:ops`, 446 generated tokens in 13.762 seconds, `/Users/gunnaire/Documents/GunnAireLocalQA/runs/test-draft-4cawv6i0/report.json`. Only the reviewed classifier source and synthetic boundary requirements were sent to loopback. Three proposed tests were independently reviewed and simplified; the recursion test was strengthened with both accepted and rejected depth boundaries. No suggested code was automatically applied or executed. No cloud fallback or Stable Diffusion was used.
- Source fingerprints: `CandidateSource.sha256`. All eleven source/test files stayed frozen through final qualification and match the original iCloud project after guarded copyback. Unrelated owner files are unchanged. Commit metadata is recorded separately in the evidence directory.

Tests use actual receive/setup/coordinator/editor implementations with synthetic transport responses and stored content. Coverage includes setup/core/full/open outages, missing cold-start authority, blocked error classes, partial successors and draft review, deadline/device/session invalidation, role/account changes before timeouts, first-page revocation, corrupt setup journals and concurrent/late refresh completion. Controller and build evidence is not visual, signed-device or real provider acceptance.

## Remaining full-goal work

The production-suite goal remains ACTIVE. Complete competitor-derived workflows, QBO item/invoice/document/time synchronization, Google/vendor integration acceptance, independent signed-account CloudKit testing, physical iPad-to-iPhone payment handoff/Tap to Pay, and distribution/privacy acceptance remain required. This slice does not certify those features.

Further internal work includes scene/background and cold-start offline recovery, projection-directory cleanup, complete field workflow/UI coverage and full-suite acceptance. No screen capture, UI automation, physical installation, signing change, accounting/payment write, push, merge or deployment was performed here.

The offline and interface skills guided retained drafts and a contextual status banner. Identity guidance required typed network evidence and fail-closed authority checks, including partial setup results; troubleshooting required a real failing baseline. Audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`.

Apple references checked: [CloudKit network failure](https://developer.apple.com/documentation/cloudkit/ckerror/networkfailure), [network unavailable](https://developer.apple.com/documentation/cloudkit/ckerror/networkunavailable), [CFNetwork offline error](https://developer.apple.com/documentation/cfnetwork/cfnetworkerrors/cfurlerrornotconnectedtointernet), and [CFNetwork error domain](https://developer.apple.com/documentation/cfnetwork/kcferrordomaincfnetwork), including their Markdown content and installed SDK error constants.
