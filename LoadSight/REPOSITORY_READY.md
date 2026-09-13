# GitHub repository preparation — 2026-09-10

## Reproducible source archive

See [GitHub handoff](GITHUB_HANDOFF.md) for the source archive command, manifest, exact scope and Ops integration dependencies. The archive captures its recorded development snapshot; newer work below is verified separately. Historical UI evidence applies only to its recorded milestone. Temporary render previews and dependency symlinks are now excluded by `LoadSight/.gitignore`.

## Repository data reviewed

Reviewed [Autbellum/GunnAire-Ops](https://github.com/Autbellum/GunnAire-Ops) at `e17fec5fca4dfd8042096f7f833db829a0bbcb63` (main), through a separate shallow bare clone. The remote includes the native Ops app, canonical Backend service, supplier-readiness model changes and Carrier Enterprise onboarding metadata. It does not yet contain LoadSight or a plugin directory. Those sources informed retaining the existing app/backend boundary instead of introducing another service authority.

The workspace checkout differs from that remote revision and contains pre-existing changes. No merge, commit, push or deployment was performed. These files prepare the current working tree for review; this is not a claim that the remote main branch or hosted CI has passed with them.

Remote `main` was rechecked with `git ls-remote` on 2026-09-10 and still resolves to the revision above.

## Prepared files

- `README.md`: links the mechanical application and plugin to existing Ops/backend documentation.
- `LoadSight/README.md`, `CONTRIBUTING.md`: architecture, clean-checkout commands, evidence expectations and incomplete scope.
- `Plugins/gunnaire-ops/`: manifest, 12 skills, references, portable wrapper and eleven boundary tests. Repository source version is 0.1.0; installation is managed separately from repository source.
- `.github/workflows/loadsight-regression.yml`: shared tests, 20-operation plugin regression, unsigned iPad compilation and retained logs. Uses least-privilege contents-read permission and pinned action commits.
- `.github/workflows/native-app-regression.yml`: includes Ops/LoadSight opening, customer/job linking and local draft restart recovery in iPad shard zero.
- `.github/PULL_REQUEST_TEMPLATE.md`: behavior, actual verification and remaining-scope prompts.
- `.gitignore`: preserves the LoadSight shared scheme while excluding Python caches and native result bundles.

The workflow pins Xcode 26.6 on macOS 26, matching the existing native workflow and the [GitHub runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md) checked on this date. Hosted execution begins only after the changes reach GitHub.

## Latest automatic discovery milestone

The current source passes **322 shared tests**, **12 wrapper tests**, Mac compilation and a **25.155-second native discovery/source/review/save/reopen/read test**. Repository and installed real-engine checks pass; the plugin also reads the actual native-authored map. Production source matches the native build. CI has 19 syntax-checked run steps. See [discovery verification](Reference/verification/Schedule-discovery.md).

## Earlier sourced unit convention milestone

The current source passes **308 shared tests**, Mac compilation and a **92.835-second native iPad convention/save/disk-reopen test**. Repository and installed plugins verify the source-bound conversions; the repository plugin also reads the actual native-authored package. Production files match the native source copy. CI has 18 syntax-checked run steps. See [unit convention evidence](Reference/verification/Schedule-unit-conventions.md).

## Earlier ordered dimension milestone

The current source passes **300 shared tests**, Mac compilation and a **16.730-second native iPad dimension review test**. Repository/installed plugin checks verify interpreted, missing and unresolved dimensions with original text intact. Production files match the native build copy; CI has 17 syntax-checked run steps. See [dimension verification](Reference/verification/Schedule-dimensions.md).

## Earlier sourced schedule RFI milestone

The current combined source passes **297 shared tests**, Mac compilation and a **27.427-second native iPad RFI save/register test**. Repository and installed plugin checks verify exact source snapshots, unanswered status and atomic invalid-request rejection. Production hashes match the native build. CI has 16 syntax-checked run steps. See [schedule RFI handoff](Reference/verification/Schedule-RFI-handoff.md).

## Earlier conditional consistency milestone

The current source snapshot passes **281 shared tests**, Mac compilation and a **14.217-second native iPad consistency disclosure test**. Repository and installed plugin checks cover conflict, missing and no-conflict rows without modifying source bytes. CI has 15 syntax-checked run steps. Production hashes match the native build. See [consistency verification](Reference/verification/Schedule-consistency-review.md).

## Earlier numeric schedule review milestone

The current source snapshot passes **274 shared tests**, Mac compilation and a **12.123-second native iPad numeric review test**. Separate conversions preserve original rows and unknowns. Repository and installed plugin checks pass, and the existing CI schedule verifier now checks the numeric output. See [numeric schedule evidence](Reference/verification/Schedule-numeric-review.md). Eleven wrapper tests remain the latest wrapper-boundary result; the wrapper code was unchanged for this milestone.

## Earlier schedule map authoring milestone

The latest source snapshot passes **269 shared tests**, **eleven wrapper tests**, Mac compilation and a **72.413-second** native iPad map-authoring test. The test rejects incomplete geometry, accepts corrected entry, writes an actual `.loadsight` package and reopens its saved map. The repository plugin reads three rows from that native-authored package. Current production hashes match the native snapshot at handoff.

Native maps now retain full revision history, stale-edit checks and drawing-source validation through package, portable JSON and recovery storage. CI contains 14 syntax-checked shell steps. See [schedule map authoring verification](Reference/verification/Schedule-map-authoring.md). The older results below are historical snapshots.

## Earlier local verification

The latest recorded shared-engine snapshot passed **241 XCTest tests** with zero failures. Mac and iPad simulator builds passed. Nine portable wrapper tests were rerun successfully during this handoff; the repository plugin manifest validates. CI YAML parses and all 12 embedded shell steps pass `bash -n`.

The synthetic iPad mechanical-text test passed in 29.047 seconds: scan, open the original source page with the full text-anchor rectangle, create a local RFI, then find it in the RFI register. Repository and installed plugin extraction checks preserve original bytes and quantities, and reject stale candidate IDs and output overwrite. See [Mechanical text extraction](Reference/verification/Mechanical-text-extraction.md).

Earlier verified milestones remain documented in [Ops embedded workspace](Reference/verification/Ops-embedded-workspace.md), [draft recovery](Reference/verification/Embedded-draft-recovery.md), [catalog mapping](Reference/verification/Catalog-material-mapping.md), [catalog comparison](Reference/verification/Catalog-snapshot-comparison.md), [supplier quote validity](Reference/verification/Supplier-quote-validity.md), [SDK service](Reference/verification/SDK-service.md), and [native workbook preparation](Reference/verification/Workbook-preparation.md).

Eight production source files changed concurrently after the extraction source snapshot: `LoadSightOperation.swift`, `ChangeOrderWordDocument.swift`, `RFIWordDocument.swift`, `DraftProposal.swift`, `MechanicalTextWorkspace.swift`, `WorkbookPreparation.swift`, `WorkspaceView.swift`, and `MechanicalTextExtraction.swift`. Preserve those edits. Recorded native/build results apply to their captured snapshot; run regression CI on the final reviewed commit. Hosted CI and physical-device acceptance are not established by these local checks.

## Review handoff

Use `GITHUB_PR.md` for a review description. Review the LoadSight and plugin additions together with the existing Ops integration changes; this working tree also contains unrelated active Ops/backend work. Select reviewed changes explicitly instead of staging the entire working tree. Generated local evidence under `output/` remains excluded; repository verification documents record the checks and scope.

## Product work still required

Complete engineering methods, semantic drawing extraction, customer/job synchronization, live supplier verification and catalog publication, authenticated release/billing publication and broader device/export acceptance remain in `BUILD_STATUS.md`. GitHub packaging does not close the full application objective. Review existing source ownership and third-party notices before choosing a release license; no new license has been assigned.

Skill decisions are recorded in `~/.codex/skill-audits/skill-usage.jsonl`. Reliability guidance shaped read-only CI permissions, retained evidence and the distinction between local checks and production/hosted release.

