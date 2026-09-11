# Native office invoice recovery and review — 2026-09-11

## Candidate scope

The native office workflow now has an encrypted, account/company/environment/
replica/store-scoped journal, an explicit preview-and-apply coordinator, and a
focused review sheet. Administrators reach it from Invoices → Field Invoice
Requests or Company Workspace Review. Technicians still submit immutable field
requests; viewing them never approves prices or changes an invoice automatically.

The complete application goal remains **ACTIVE**. This is not deployment,
independent-account CloudKit acceptance, live QBO/payment acceptance, or visual
and interaction qualification of the app.

## Original intent and recovery

- Preserve the original field request/review, approved complete proposal, and
  exact encoded prepare bytes before the first remote claim. The encrypted
  store caps retained data at 64 MiB; limits fail closed without dropping work.
- Validate current operation authority before/after awaits and local storage
  boundaries. The shared owner HTTP transport now checks session expiry as
  well as current role, store and token identity; no staff exception is added.
- Require backend `2026.09.11.64` or later before preparing/recovering approvals.
  `.63` had the endpoints but lacked the shared QBO/payment safeguards described
  in `INVOICE_APPLICATION_PUBLICATION_GUARDS.md`. This check is a prerequisite,
  not a claim that the production backend is deployed or accepted.
- Compare the server's complete retained proposal with the original, in addition
  to receipt identity, chronology, state and opaque proposal digest. Do not
  recompute Python JSON hashes from Swift's numeric representation as proof.
- Persist exclusive claim, entry into the model-save boundary, and saved state.
  Retry original identities through lost prepare/save/confirmation responses.
  An already-published application is never reapplied to a later invoice.
- Only a documented prepare rejection plus a fresh absent server claim may
  retire an unclaimed intent. Keep its original bytes in a bounded rejection
  archive and require another explicit human review. Unknown replies, failed
  evidence reads and existing claims remain pending.
- Pending failures use normal sync backoff; only unread review pages request
  rapid continuation. Recovery and confirmation use bounded, round-robin work.
  Completed server history is excluded from the action queue, not deleted.

## Workflow and UI

Recovery of already-approved work precedes the full owner workspace capture.
The actual owner publisher must finish without conflicts or iCloud wait state
before source confirmation and refreshed invoice review. Its existing final
history fence remains before core capture and subsequent CloudKit delivery.

Preview uses the full sold snapshot, including original lines, bundle totals,
package/system details and retained discount. Existing sold prices are not
silently refreshed. Group contents remain inspectable regardless of customer
print preferences. The approval reason is explicit, and changed reason/session/
invoice evidence invalidates the preview. Account changes dismiss retained
review sheets through display-generation invalidation.

The screen explains that approval clears stale signatures and tax calculation.
It does not show JSON, provider payloads or a signed-in email footer. This scoped
sheet follows Apple's [sheet guidance](https://developer.apple.com/design/human-interface-guidelines/sheets)
to keep a related decision separate from the main invoice list. This design
choice is not a substitute for visual/accessibility/device acceptance.

`published` means the exact invoice/item reached the company source. It does
**not** mean QuickBooks accepted it; the original receipt remains
`qboPublished: false`. Sending documents, QBO publication and collection remain
separate explicit actions using the existing guarded workflows.

## Verification

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Native Invoice Recovery.Xs5tk0`.

Local qualification is complete for this slice. The initial pre-refinement native run passed
43 tests (16 coordinator, 27 existing invoice). `focused2` retains the
navigation-initializer compile failure; it is not a successful test run.
The expanded `focused3` run passes 91 tests with all four requested selectors
verified from its xcresult summary/tree. The first complete run, `full1`, passes
2,343 tests and fails only the new flow test's single-pass assumption. Inspection
of the actual publisher confirms it deliberately returns `hasMore` after a
changed batch. The corrected test checks the retained prepared/saved state on
pass one and drives the next bounded verification pass; it does not bypass the
publication fence. `full1` is retained as a failed run, not final qualification.

| Check | Confirmed result / evidence |
| --- | --- |
| Expanded focused native | 91 passed, zero failures/skips; `focused3-summary.json`, `focused3-tests.json`; four requested selectors verified. |
| Final full native | 2,344 passed, zero failures/skips: 427 XCTest + 1,917 Swift Testing. `full2.xcresult`, `full2-summary.json`, `full2-tests.json`; all nine required selectors independently verified. |
| Backend guard/native interop, Python 3.9.6 | 38 passed in 18.642s; `backend-interop.log`. No backend implementation changed in this slice; this does not claim a new complete backend regression. |
| Local tooling | 75 passed; `/Users/gunnaire/Documents/GunnAireLocalQA/runs/tools-mk3khafy/report.json`; no inference requested. |
| Unsigned Mac Catalyst Release | Passed; `mac-final.log`; binary independently verified as `x86_64 arm64`. Two existing Metal toolchain search-path linker warnings remain, one per architecture; none suppressed. |
| Unsigned iOS Release | Passed; `ios-final.log`; binary independently verified as `arm64`. |

`sources-final.sha256` freezes all ten implementation/test inputs and was
rechecked after the full native run. All final qualification handles finished
with exit zero. Do not use initial runs to qualify later source changes.

Native test command: `xcodebuild -project 'GunnAire Ops.xcodeproj' -scheme
'GunnAire Ops' -destination 'platform=iOS Simulator,id=0ADE5A1A-9859-4377-AD5E-93FC6D70F1D3'
-derivedDataPath /tmp/GunnAire-ops-loadsight-ipad-derived -jobs 2
-parallel-testing-enabled NO '-only-testing:GunnAire OpsTests'
-resultBundlePath '<evidence>/full2.xcresult' CODE_SIGNING_ALLOWED=NO test`.
This is the hidden iPad unit-test target, not `GunnAire OpsUITests`.

The tests use synthetic actual SwiftData records and injected transport/storage
failures. No live business data, provider writes, UI test target, screen capture,
foreground activation, signing change or physical-device installation is used.

## Actual owner-composite qualification

The owner also contains parallel LoadSight discovery/association work not
present in the candidate commit. That work was preserved, not overwritten.
All nine build-input roots (637 files, including new owner files) were copied
to the private local snapshot
`/Users/gunnaire/.codex/worktrees/OpsOwnerComposite.JuVXOE`.
`owner-snapshot-inputs.json` records exact paths, sizes and SHA-256 hashes.
After every test and Release build, the owner's complete input file set and
all 637 original/snapshot hashes still matched.

The initial direct iCloud-hosted build was cancelled before compilation
(exit 130), after a process-stack sample showed a coordinated-file-read wait
while opening the project. The access-claim holder was not identified. Only
copied filesystem extended attributes on the private snapshot were cleared;
no owner file, service, signing or iCloud setting was changed.

| Owner-composite check | Confirmed result / evidence |
| --- | --- |
| Full hidden iPad unit suite | 2,344 passed, zero failures/skips. Fresh `xcresulttool` summary/tree matches retained evidence; nine required selectors verified. `owner-snapshot-full1.xcresult`. |
| LoadSight package | 322 passed, zero failures. Includes six discovery and two preparation cases; `owner-package1.log`. |
| Unsigned Mac Catalyst Release | `BUILD SUCCEEDED`; `owner-mac-release1.log`. Binary verified as `x86_64 arm64`. |
| Unsigned iOS Release | `BUILD SUCCEEDED`; `owner-ios-release1.log`. Binary verified as `arm64`. |

The Mac build retains two missing optional Metal toolchain search-path linker
warnings, one per architecture. Fresh Debug compilation also exposed five
existing test-only warning locations (one unused variable and four redundant
`#require` diagnostics); none was suppressed. No production/UI/provider
acceptance is inferred from these results. The owner branch, HEAD and index
remain unchanged; exact values and the qualification commands are retained
in the evidence directory's `NOTES.md`.

## Remaining production requirements

Safely resolve already-claimed invoice conflicts and original-device loss;
archive-only recovery applies only when a fresh server read proves no claim.
Qualify the complete technician → office → catalog/QBO invoice → reconciliation
path with real provider sandbox evidence, then production acceptance. Verify
two-device/independent-account CloudKit convergence, iPad/iPhone collection
handoff and supported reader behavior. Complete iPad/Mac visual, keyboard,
pointer, VoiceOver and device acceptance when screen interaction is permitted.
All broader feature/release requirements remain tracked in
`COMPLETION_EVIDENCE_MATRIX.md`; this slice does not redefine completion.

## Local AI and skill audit

One bounded Ollama `gunnaire-coder:ops` advisory call reviewed only this
non-secret source file: 560 tokens in 19.157 seconds. It produced inapplicable
Python mocks for Swift types and was rejected, not applied or executed.
Report: `/Users/gunnaire/Documents/GunnAireLocalQA/runs/test-draft-pkeu1jg1/report.json`.
All actual regression code was independently reviewed against the native types.
No image-generation service or app LLM configuration was added; this hosted
task remains hosted. Tests execute locally without model inference.

Skill guidance shaped original-intent durability, authorization at every
suspension boundary, exact sold evidence, scoped UI and explicit accounting
status. Audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`, task
“Connect native office invoice review and durable application recovery”.
