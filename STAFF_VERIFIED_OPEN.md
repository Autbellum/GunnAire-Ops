# Verified staff workspace opening — 2026-09-11

## User-facing change

Staff receive now completes import, activation, fresh server/participant CloudKit proof, readiness, host opening and device identity binding before exposing a workspace. A stored `ready` or `bound` flag is no longer enough. Host, identity and account context are published together, and screens and field-edit entry points recheck current session, expiry and independently obtained installation evidence.

An unchanged refresh retains the same SwiftData container but still checks server authority. A newer snapshot replaces the container only after its complete session validates. The selected sidebar section survives content replacement within the same authorized workspace; account/role/device scope changes reset it. Recovery text is short and the unbound presentation fallback is removed.

## Regression and qualification

The retained baseline regression against `d33adaf321103c366bb835a1c8a4e972329403bb` failed because identity-binding failure still exposed the hosted store and allowed field-edit authority. The original test-only patch and failing result are retained as `BaselineRegression.patch` and `Red1.xcresult`.

New real-pipeline fixtures start with only mounted/accepted content, then verify first opening, same-container refresh, successor publication, server denial and recovery, stale returned sessions, account invalidation, changed installation evidence, expiry, concurrent source change, malformed inputs, real saved-identity binding failure, mismatched identity fields, cancellation after suspension and refresh coalescing. Original regression assertions remain. Fixtures use synthetic data, a local dictionary journal store and in-memory CloudKit transport; they make no provider or CloudKit writes.

Final local qualification:

- Focused iPad-simulator logic: **108 passed**, zero failures/skips, all nine requested selectors verified from xcresult.
- Full iPad-simulator logic: **2,203 passed**, zero failures/skips, all nine affected selectors verified from xcresult. All 13 new session tests and the retained binding-failure regression executed successfully.
- Backend: **1,102 passed**, Tools: **75 passed**; both ran through the local helper without model inference. Reports: `/Users/gunnaire/Documents/GunnAireLocalQA/runs/backend-d5lzya_p/report.json` and `/Users/gunnaire/Documents/GunnAireLocalQA/runs/tools-b6je19uk/report.json`.
- Mac Catalyst unsigned universal Release: **passed**, `x86_64 arm64` verified at build `2026090506`. Only the existing missing Metal-toolchain search-path warning remains; the old unused presentation-identity warning is gone.
- The nine scoped source/test fingerprints remained identical through native qualification.

`Green1.xcresult` is an excluded compile failure caused by a test fixture lacking explicit MainActor isolation, corrected before `Green2`. Results and source fingerprints are in `/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Verified Open.eqFLe4`. Test warnings remain in unchanged `StaffReplicaSourceHistoryTests.swift` (redundant optional unwrap) and `StaffWorkspaceOperationalImportTests.swift` (unused fixture value); they were not suppressed.

## Scope and remaining work

This is an implementation and headless-test checkpoint, not production or visual acceptance. UI tests, screen access, physical app launches, provider writes, signing, deployment, push and merge are excluded. All nine source/test files were applied to the original iCloud project after fresh preimage checks and match the qualified source fingerprints. Its branch, HEAD and index were preserved; unrelated owner/parallel changes were untouched. Tests qualify the validation checkout, not unrelated changes in the owner project.

The full application goal remains ACTIVE. Complete competitor-derived workflow coverage, natural iPad/Mac journeys, QBO item/invoice/document/time reconciliation, independent signed-account CloudKit and offline recovery, physical iPad-to-iPhone payment handoff, approved Tap to Pay, Google/supplier acceptance and distribution verification remain required.

Known limitations of this checkpoint: a failed refresh hides the current workspace while keeping saved drafts; active record-navigation paths/editor sheets may reset on a successor even though the sidebar selection survives; normal-lifetime temporary projection-directory retention still needs a bounded cleanup policy. Do not generalize this checkpoint into flawless offline or complete UI continuity.

Offline and identity skills drove saved-work preservation and independent authorization fences; the interface skill drove atomic screen replacement, concise states and retained sidebar selection. The skill audit is `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`. Current Apple sidebar guidance was checked at <https://developer.apple.com/design/human-interface-guidelines/sidebars?changes=_11>.
