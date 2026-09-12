# Office invoice follow-up handoff — 2026-09-11

## User workflow

After the company source confirms an office approval, Invoice Follow-up offers
Open Invoice for the original saved bill. A local save alone does not offer
the editable follow-up. Published request history can restore it after restart.
The follow-up list keeps at most eight distinct invoice identities in memory;
completed requests remain outside the approval queue and retained on the server.

The focused invoice opens its saved row expanded in the existing stack-safe
invoice workspace. It retains line-item editing, PDF generation, billing review
and collection controls. General metrics, unrelated work queues and the new
invoice picker are absent. Sync Saved Invoice is an explicit action on the
existing saved-invoice row, including the ordinary Invoices workspace.

Opening the focused invoice does not initialize/save templates, import catalog
items, consume another queued job route, apply a field request, publish a QBO
record or collect payment. Existing guarded QBO customer/item/invoice and file
publication workflows remain authoritative. Source confirmation is still not
QBO confirmation, and the backend version/publication safeguards are unchanged.

## Identity and recovery

Navigation retains the original company, environment, replica, owner store,
session stamp, invoice, customer and optional job identities, not a SwiftData
object. At the destination, current authority is checked before reading model
fields and again before returning a match. A single original invoice and
customer must exist; a linked job must be unique and have the same customer.
Standalone invoices do not invent a job. A later local approval retires an
earlier follow-up for that invoice. Retained local approvals suppress cached
and historical links until durable recovery finishes. Duplicate UUIDs never coalesce into
an arbitrary destination. Milestone reconciliation still evaluates the complete
invoice graph before the focused result is selected.

Account/container changes and session expiry replace the destination with a
recoverable unavailable state. Changing the coordinator's display generation
closes retained review/invoice sheets. Failed model saves retain the original
approval journal and do not expose a successful follow-up. Navigation does not
resolve an already-claimed approval or provide lost-device claim recovery.

The interface uses existing native disclosure and sheet conventions. Apple's
[disclosure guidance](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls?language=objc)
supports keeping incidental details hidden until needed; the selected invoice
is expanded because its details are the purpose of this visit. This design
rationale is not visual, accessibility or physical-device acceptance.

## Qualification status

Evidence: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Invoice Handoff.yVG97N`.
The initial focused run passed 59 tests, zero failures, before the final
standalone/company cases and full-graph filtering refinement. Do not substitute
that initial result for final-source qualification. `candidate-inputs.sha256`
freezes the five implementation/test inputs for the expanded pass.

| Check | Result |
| --- | --- |
| Pre-refinement expanded focused native | 122 passed, zero failures/skips; all six selectors verified from `focused2.xcresult`, summary and test tree. |
| Pre-refinement full candidate native | 2,354 passed, zero failures/skips; all nine selectors verified from `full1.xcresult`, summary and test tree. |
| Tools, final source | 75 passed; `/Users/gunnaire/Documents/GunnAireLocalQA/runs/tools-y99agke8/report.json`; inference not requested. |
| Actor-refinement focused native | 122 passed; all six selectors verified from `focused3.xcresult`, summary and test tree. No app-source warning. |
| Pre-confirmation-gate owner full native / Release | `owner-full2` passed; both `owner-*-release2` builds passed. These precede the final ordering guard and additional restored-journal test, so are not final qualification. |
| Final actual owner full native | 2,355 passed, zero failures/skips; `owner-full3.xcresult`, summary and test tree. Eleven required selectors independently verified, including both exact confirmation-ordering methods. |
| Final actual owner unsigned Mac/iOS Release | Both passed; `owner-mac-release3.log` / `owner-ios-release3.log`. Produced architectures independently verified as Catalyst `x86_64 arm64` and iOS `arm64`. |

Final qualification is complete for this slice. All final qualification commands
exited zero. After completion, all 639 owner/snapshot inputs, the complete owner
input file set, and all five candidate implementation/test hashes still matched.
There are no app-source compiler warnings in the final runs. Two existing Mac
Metal toolchain search-path linker warnings remain, and simulator logs retain
non-failing AppShortcut/haptics asset diagnostics; none was suppressed.

Fresh owner compilation exposed an actor-isolation warning at the original
authorization method-reference conversion. The destination and callback type
are now explicitly main-actor isolated, and the adapter uses a closure like
the sibling source/publication coordinators. No isolation warning was suppressed.
The first three owner runs were deliberately interrupted (exit 75) to qualify
the corrected source instead; their logs retain `TEST/BUILD INTERRUPTED` and
are not successful qualification. The earlier candidate results above precede
this refinement and do not replace final-source verification.

The subsequent ordering review removed the immediate post-save shortcut: normal
invoice editing must not be invited by this handoff while the original source
confirmation is pending. An additional restored-journal test checks cached link
removal and recovery without reapplying the invoice. There are eleven new
navigation tests. This is a handoff gate, not a new global edit lock across all
invoice screens or a replacement for claimed-conflict/device-loss recovery.

All five implementation/test files were copied into the owner project with
guarded patches and compared byte-for-byte. The owner branch remains
`codex/internal-team-tasks-20260830`, HEAD
`ff2189c3dfe9cc2d3e2ca79cbf1a6b53572aa45c`; index SHA-256 remains
`19b5872ad9b8c52ee43bd28c7075b93efaac46a933a09abda91dd2705bde254d`.
No parallel source was overwritten. The private, exact owner build snapshot is
`/Users/gunnaire/.codex/worktrees/OpsInvoiceHandoffFinal.mCBYjk`.
`owner-qualified-composite.json` freezes its 639 original input paths and a combined
path/size/content digest. All 181 LoadSight build-input files remain unchanged
from the earlier owner package run (322 passed); no new package run is claimed.
The first snapshot and `owner-composite.json` are retained separately for the
interrupted pre-refinement runs. After every second-pass owner process finished,
its inputs were copied unchanged to
`/Users/gunnaire/.codex/worktrees/OpsInvoiceHandoffPreConfirmation.l4AXQ4` and
checked against `owner-final-composite.json`. Only then were the two ordering-
guard implementation/test files patched in the working snapshot for pass three.
Final source hashes are in `scopedInputs` in `owner-qualified-composite.json`;
the earlier two manifests and `candidate-inputs.sha256` remain historical.

Native commands use the hidden iPad Pro 13-inch (M5) simulator
`0ADE5A1A-9859-4377-AD5E-93FC6D70F1D3`, two jobs, disabled parallel testing,
`-only-testing:GunnAire OpsTests` (or the recorded focused selectors), and
`CODE_SIGNING_ALLOWED=NO`. Release builds use `generic/platform=iOS` and
`generic/platform=macOS,variant=Mac Catalyst`, two jobs and signing disabled.
Candidate derived data is `/tmp/GunnAire-ops-loadsight-ipad-derived`; owner unit,
Mac and iOS derived data are `/tmp/GunnAire-ops-owner-composite-derived`,
`/tmp/GunnAire-ops-owner-composite-mac-derived` and
`/tmp/GunnAire-ops-owner-composite-ios-derived` respectively.

No live provider writes, UI tests, screen access, foreground launch, deployment
or signing change has occurred. Deterministic tests run locally without
inference. No image service or app LLM endpoint was used or added.

## Remaining scope

The complete production goal remains ACTIVE. This slice does not establish
claimed-approval/device-loss recovery, live QBO acceptance, independent-account
CloudKit convergence, iPad/iPhone tap-to-pay acceptance, or iPad/Mac usability
and release readiness. All broader requirements remain in
`COMPLETION_EVIDENCE_MATRIX.md`.

Skills shaped the original-record identity checks, explicit accounting action,
bounded follow-up list, and reuse of the stack-safe invoice view. Audit:
`/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`, task
“Connect office invoice approval to the existing invoice workflow”.
Latest account snapshot: 48% consumed, 52% remaining. This hosted task was not
switched to a local model; the tests/builds themselves used local execution
without inference. No new hosted feature slice was started after this check.
