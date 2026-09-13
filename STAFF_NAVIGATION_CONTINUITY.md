# Staff record and editor continuity — 2026-09-11

## Implemented connection

The staff navigation stack now carries lightweight `(kind, id)` routes and lives independently of the current snapshot's record views. It is stable across content replacement within a verified workspace. List/detail query views are recreated against the new staff-only ModelContainer; the open record is resolved by compound identity, not a retained SwiftData row. This also avoids list identity collisions when different record kinds use the same UUID.

An editor session is owned by per-window navigation state above snapshot replacement. Its controller and unfinished input stay intact across successful refreshes. Live dependencies resolve the currently authorized host only within the original account/session/scope/role/device authority. The previous host object itself remains unauthorized for editing. The draft stays attached to its original source and record revision until the user explicitly reviews it against the current field. Typing while receive is pending stays in the same editor and is retried locally after verified refresh; no automatic submission or rebasing occurs.

Changing sections clears the old record path. Missing records recover to the list with a short message. Unavailable fields, revoked access, account/device changes and reauthentication clear private navigation/editor state while preserving previously saved drafts. Existing unsaved-change dismissal confirmation remains. The UI adds no new top-level destination or automatic provider action.

## Reproduction and qualification

Baseline: `3d6b5956eaddcc89bc701450ecb0ad8805b28ee8` plus dependency injection for the same existing live editor implementation. The retained regression failed because refreshing the host cleared `draft`, input and current-field review from the live editor. `RedTestability.patch`, `OriginalRegression.swift`, `Red1.log` and `Red1.xcresult` preserve that reproduction. A default-argument actor warning in the injection-only version was corrected by resolving the optional receiver inside the function.

Final local qualification:

- Focused iPad-simulator native logic: **74 passed**, zero failures/skips, all six requested selectors verified from xcresult, including all seven new navigation/editor tests.
- Full iPad-simulator native logic: **2,210 passed**, zero failures/skips; all six affected selectors independently verified from xcresult.
- Unsigned universal Mac Catalyst Release: **passed**, `x86_64 arm64` verified at build `2026090506`. Existing Metal-toolchain search-path warnings remain; the injection-only actor warning is gone. Existing unchanged test warnings are not suppressed.
- Tools: **75 passed** without model inference, `/Users/gunnaire/Documents/GunnAireLocalQA/runs/tools-8qm7elyp/report.json`. Backend code was unchanged and was not retested in this checkpoint.
- All seven source/test fingerprints remained frozen during qualification and match the original iCloud project after protected copyback. Owner branch, HEAD and staging index remain unchanged; unrelated owner/parallel edits are not part of this qualification.

Evidence directory: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Navigation Continuity.H9O4ja`. Commands are retained in build logs, with xcresult summaries/test trees and `CandidateSource.sha256`.

Tests exercise the actual receive/coordinator/editor dependencies with synthetic mounted data and independent server/participant responses. They cover successor content, changed office notes/revision, explicit draft review, typing across a suspended receive, current-container row replacement, identity isolation, stale-row refusal, restricted fields, compound route IDs, missing routes and section changes. Headless controller/query tests do not establish visual or actual SwiftUI transition acceptance.

## Scope and next work

The full application goal remains ACTIVE: complete competitor-derived workflows, iPad/Mac usability, QBO staff item/invoice/document/time synchronization, independent signed-account CloudKit/offline acceptance, physical iPad-to-iPhone payment handoff, approved Tap to Pay, Google/vendor and distribution acceptance remain required.

This checkpoint does not resolve the receive controller's failed-refresh workspace-hiding behavior, temporary projection-directory lifecycle, draft-save failures during a lost-access/failed-receive transition, or complete offline/visual usability. Previously saved drafts are retained; unverified latest input must not be represented as durable. No physical installation, screen capture, UI automation, signing change, provider/accounting write, push, merge or deployment is part of this checkpoint.

The interface and offline skills guided lightweight navigation state and original-version draft retention; identity guidance preserved independent current authority. Audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`. Apple navigation guidance checked: <https://developer.apple.com/documentation/swiftui/understanding-the-navigation-stack> (including its Markdown page).
