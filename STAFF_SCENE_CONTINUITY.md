# Staff scene handoff and local capture — 2026-09-11

## Implemented lifecycle

The app-level SwiftUI scene phase now controls staff recovery. Apple defines this phase as active while any app scene is active, so an inactive window no longer clears another window's shared presentation. Workspace and setup views enable a single controller-owned recovery loop instead of owning competing, cancellable receive loops. Sign-out explicitly stops recovery and clears the presentation; gaining owner-store access also stops the staff loop.

The receive controller owns each active request, forwards caller cancellation, and fences publication by generation. App deactivation invalidates late publication before cancelling transport, retains only an already verified session and pauses automatic work. A rapid resume waits for the old request/worker to drain before starting one successor. An ordinary cancelled caller, revoked access, invalid data or storage failure still cannot use the pause path as offline authorization. Existing account-generation, role, plan, device and expiry checks remain; reactivation rechecks them. No cold-start lease is invented.

Local draft persistence now has its own narrowly scoped authority check. It can finish while receive is pending or the app is becoming inactive, but it still checks the original account/role/device and uses the existing original-draft compare-and-swap rules. It cannot queue, send, review or rebase an office mutation. Typing stays available while a network refresh is pending; current-record actions remain disabled until their stricter checks pass. A storage failure stays explicitly unverified and retryable. The editor attempts persistence before disappearing and pauses lifetime polling while its scene is inactive.

Each scene delegate installs a plain opaque privacy cover above its windows, including app sheets, before backgrounding. It does not capture an image or remove the underlying view hierarchy. Reactivation enforces workspace deadlines before removing the cover. This is an implemented privacy measure, not yet physical-device/app-switcher visual acceptance.

## Reproduction and tests

Baseline: `56736fa32023e5b427a591d5e8600bcc95e157a8`. `RedTestability.patch` extracts the existing inactive-scene `clearDisplay` action into the same method called by the live modifier; it does not change that behavior. The regression reproduced loss of the hosted workspace, editor draft and displayed text: one test, three failing assertions, xcodebuild exit 65.

Evidence directory: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Scene Continuity.9V9gcQ`.

- Initial focused native run: **70 passed**, six requested selectors independently verified, no failures/skips.
- Initial full native run: **2,237 passed**, six affected selectors independently verified, no failures/skips.
- Final application-source full run (`FullNative2`): **2,237 passed**, six affected selectors independently verified, no failures/skips; xcodebuild exit 0. The only later change was modernization of the hidden test-window initializer, not application code.
- Final scene/privacy harness checks (`SceneFinal`): **12 passed**, requested selector independently verified, no failures/skips; xcodebuild exit 0. Uses `UIWindow(windowScene:)` without making any window visible. No warnings from the new test source remained.
- Universal unsigned Mac Catalyst Release (`MacRelease2`): **BUILD SUCCEEDED**, exit 0, actual binary verified as `x86_64 arm64`, build `2026090506`. The pre-existing missing MetalToolchain search-path warning remains. `MacRelease1` was deliberately cancelled (exit 75) when the editor-availability correction changed the candidate; it does not qualify the final app source.
- Tools: **75 passed**, no inference, `/Users/gunnaire/Documents/GunnAireLocalQA/runs/tools-pondet1i/report.json`.
- Local Ollama advisory: `/Users/gunnaire/Documents/GunnAireLocalQA/runs/test-draft-j_1dooc_/report.json`, pinned `gunnaire-coder:ops`, 424 output tokens in 15.699 seconds. The draft was rejected without applying or executing it: it used live default controllers, immutable/private fields and timing-based sleeps contrary to the supplied fixture contract. The three requested edge cases were authored against the actual fixture and controller instead. Only reviewed source went to loopback; no cloud fallback, image-model route or credentials were involved.

Tests cover suspended-transport handoff, latest-input durability before cancellation acknowledgement, failed draft writes/retry, expired/revoked/changed-device resume, repeated window requests sharing one worker, rapid resume, late completion after stop, cancellation before a request starts, reentrant stop, and opaque per-scene cover isolation. Test windows remain hidden; no UI automation, screen capture or desktop activation is used.

`CandidateSource.sha256` records the initial full-run candidate; `FinalSource.sha256` records the subsequent editor-availability correction. `CopybackSource.sha256` records the final 12 source/test files; only the scene test initializer differs from `FinalSource.sha256`. Final copyback fingerprints and local commit metadata are recorded separately in the evidence notes.

The 12 qualified source/test files were copied into the original iCloud GunnAire-Ops project only after the 10 existing owner files matched the validation baseline byte-for-byte and both new files were confirmed absent. All 12 owner fingerprints match `CopybackSource.sha256`. This report is copied alongside them. The owner branch, HEAD and staging index are preserved; the commit is local to the validation worktree, not a push or deployment.

## Remaining production scope

The full goal remains ACTIVE. Cold-start recovery after process termination, projection-directory lifecycle, complete competitor-derived business workflows, QBO staff items/invoices/documents/time, Google/vendor acceptance, independent signed-account CloudKit checks, physical iPad-to-iPhone payment handoff/Tap to Pay and release/distribution/visual acceptance remain required. In-memory scene continuity and synthetic tests do not prove those requirements.

No physical installation, production accounting/payment write, signing change, push, merge or deployment was performed. The offline/interface skills guided durable input and stable navigation; identity guidance kept draft capture separate from current-record actions; troubleshooting required the failing baseline. Skill audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`.

Apple references checked, including Markdown content: [ScenePhase and aggregate app state](https://developer.apple.com/documentation/swiftui/scenephase), [preparing UI for background execution](https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background). UIKit scene/window ownership stays with SwiftUI; no scene or signing capability is added.
