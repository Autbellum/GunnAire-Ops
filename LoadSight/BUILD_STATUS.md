# LoadSight and GunnAire Ops — active implementation

## Objective and source of requirements

Build the complete native macOS/iPadOS LoadSight application, reusable LoadSightKit SDK, and GunnAire Ops plugin from the latest skills and the two latest ChatGPT chats. The full objective remains active; this implementation is not completion.

- `Requirements/Build-Mechanical-Takeoff-Skills.md`: retrieved conversation `6aa29cc2-1ca4-83ea-9348-7a1206dec729`, including the mechanical-only scope and iPad changes.
- `Requirements/Mechanical-Load-Skill-Creation.md`: retrieved conversation `6aa2a193-251c-83ea-aec9-81671093cdfe`, including the user's complete system requirements. One long assistant response was capped by the retrieval tool; the full user specification was retrieved.
- `Reference/skills/`: actual skill pack recovered from `../GunnAire_Mechanical_Takeoff_v1.zip` in the iCloud root. All six companion instructions were read.
- `Reference/project/`: recovered dental and blank project JSON. Dental data is inherited prior-review evidence, not newly verified drawing content.
- iCloud `GunnAire_Mechanical_Takeoff_v2/` contains the newer touch workbench, workbook, review PDF and README. Preserve its feature scope while implementing native interactions.

## Automatic schedule discovery and editable maps — 2026-09-10

Added automatic text-layout discovery of supported equipment tables across imported pages, retaining header/tag evidence, original-case units, unknown/duplicate headers and inferred bounds. The native workspace previews source overlays and opens a source-validated editable map draft; author/reason are required to save. SDK and read-only plugin commands `schedule-discover` / `schedule-discover-review` use the same engine. Discovery never creates physical quantities or approvals.

**322 shared tests**, **12 wrapper tests**, repository/installed real-engine checks, Mac compilation and a **25.155-second native discovery/source/review/save/disk-reopen/read test** pass. The plugin also rediscovered and read the actual native-authored package. Production source matches the native build; screenshots were inspected. CI has 19 syntax-checked run steps. Installed plugin: `0.1.0+codex.20260910202251`. See [discovery evidence and heuristic limits](Reference/verification/Schedule-discovery.md).

Stacked/merged/rotated headers, table linework, multiline continuation handling, broader semantic extraction and confirmed associations remain incomplete, alongside full engineering, authenticated cloud/Ops publication and broader device/export acceptance. The full goal remains active.

## Sourced schedule unit conventions — 2026-09-10

Added source-defined MBH/Btu/ton and US/Imperial GPM conventions without changing literal schedule units. Maps require compatible definitions and recorded legend/specification evidence. Definitions and complete authored history survive native packages, portable JSON and extracted-row snapshots; changed evidence changes row identity. Native editing rejects missing evidence and retains the citation after disk reopen.

**308 shared tests**, repository/installed real-engine checks, Mac compilation and a **92.835-second native iPad source-definition/save/reopen/value test** pass. The repository plugin also reads the actual native-authored package. Production files match the native source copy; CI has 18 syntax-checked run steps. Installed plugin: `0.1.0+codex.20260910200739`. See [unit convention evidence](Reference/verification/Schedule-unit-conventions.md).

Water-column reference conditions, automatic extraction and confirmed associations, complete engineering methods, REST/cloud, authenticated Ops publication and broader device/export acceptance remain open. The full goal remains active.

## Ordered schedule dimension interpretation — 2026-09-10

Added separate dimensionReview output and native display for explicit two/three-part decimal dimensions. Lengths convert to metres in source order; literal cells remain unchanged. Missing units, mixed notation, fractions, ranges and invalid components stay unresolved. Axis names, orientation, clearance meaning and physical quantities are not inferred.

**300 shared tests**, repository/installed real-engine checks, Mac compilation and a **16.730-second native dimension/missing-cell test** pass. Production files match the native source copy. CI now has 17 syntax-checked run steps. Installed plugin: `0.1.0+codex.20260910195021`. See [dimension evidence](Reference/verification/Schedule-dimensions.md).

The concurrent fractional-count correction was preserved and its numeric tests verified. Broader unit/axis semantics, automatic extraction, complete engineering, confirmed associations, REST/cloud, authenticated Ops publication and broader device/export acceptance remain open. The full goal remains active.

## Sourced schedule finding RFI handoff — 2026-09-10

Native schedule findings can now create authored unanswered RFIs with current-row validation, a readable source summary and a linked complete JSON evidence snapshot. The shared atomic operation preserves original drawing bytes and quantities. Native draft saving uses the captured drawing-review session, dismisses the keyboard and locks saved inputs. Plugin `schedule.rfi.create` exposes the same workflow.

**297 combined shared tests**, repository/installed real-engine checks, Mac compilation and a **27.427-second native save-and-register test** pass. Production hashes match the native source copy. CI has 16 syntax-checked run steps. Installed plugin: `0.1.0+codex.20260910194209`. See [schedule RFI evidence](Reference/verification/Schedule-RFI-handoff.md).

Complete engineering, broader sourced unit conventions, automatic extraction, confirmed equipment/geometry associations, REST/cloud, authenticated Ops publication and broader device/export acceptance remain open. The full objective remains active.

## Conditional schedule consistency review — 2026-09-10

Added structured missing/unresolved coordination-field checks, conditional sensible/total cooling and outdoor/total airflow comparisons, and zero-capacity review prompts. Native findings expose the interpreted operands and required common rating basis. Partial or low-confidence evidence withholds conclusions; no finding approves equipment or physical counts.

**281 shared tests**, repository/installed real-engine checks, Mac compilation and a **14.217-second native iPad disclosure test** pass. The screenshot was inspected and production hashes match the native snapshot. CI now includes the three-state consistency fixture and has 15 syntax-checked run steps. Installed plugin: `0.1.0+codex.20260910193656`. See [consistency review evidence](Reference/verification/Schedule-consistency-review.md).

Full operating/manufacturer plausibility, sourced unit-convention selection, automatic extraction, confirmed associations, complete engineering, REST/cloud, authenticated Ops publication and broader device/export acceptance remain unfinished. The full objective remains active.

## Schedule scalar unit interpretation — 2026-09-10

Added a separate numericReview result and native cell display for supported explicit scalar units, preserving literal rows, source evidence and row identities. Missing units, ambiguous formats and unsupported conventions stay unresolved. Conversion factors and offsets remain visible; no equipment counts or engineering approvals are inferred.

**274 shared tests**, repository/installed plugin checks, Mac compilation and a **12.123-second native iPad review test** pass. Production hashes match the native snapshot, and literal rows exactly match the prior reader output. The installed CLI's stale-build symptom was resolved by preserving its old cache and rebuilding; see [numeric review evidence](Reference/verification/Schedule-numeric-review.md). Installed plugin: `0.1.0+codex.20260910193119`.

Broader unit conventions, automatic detection, plausibility, confirmed equipment association, full engineering and authenticated integration/device scope remain unfinished. The full objective remains active.

## Native schedule map authoring and durable history — 2026-09-10

Users can create and revise schedule column maps directly in the native workspace, with source/page selection, table body, column meanings, literal headers/units and source overlays. Maps and complete before/after history survive package, portable JSON and recovery storage. Shared-engine edits reject stale fingerprints, validate current drawing references and reopen QA. Removing a map retains its history.

**269 shared tests**, **eleven wrapper tests**, repository/installed plugin checks and Mac compilation pass. The **72.413-second iPad simulator acceptance** covers invalid-save feedback, corrected entry, actual disk package save/reopen and three-row extraction. The plugin also reads three rows from that native-authored package. The final screenshot was inspected; production hashes match the native snapshot. CI has 14 syntax-checked run steps. Installed plugin: `0.1.0+codex.20260910191732`. See [schedule map authoring evidence](Reference/verification/Schedule-map-authoring.md).

Automatic table/header detection, normalized units and plausibility checks, confirmed equipment/geometry association, complete engineering, REST/cloud, authenticated Ops publication and broader device acceptance remain unfinished. The full objective remains active. Earlier milestone sections below preserve their historical scope.

## Mapped equipment schedules — 2026-09-10

Added source-bound schedule regions/columns, literal cell extraction, missing/partial-cell diagnostics, repeated-tag reconciliation warnings and possible tag links. The asynchronous SDK, CLI/plugin and native Schedules workspace share the same reader; original-page overlays preserve source evidence. Missing cells stay unknown and no physical counts or approved associations are inferred.

**263 shared tests**, **ten wrapper tests**, repository/installed real-engine checks, Mac compilation and a **16.063-second iPad simulator row/source/missing-MCA test** pass. Final screenshots were inspected and production source hashes match the native build snapshot. CI adds the schedule verifier and passes YAML/13 shell-step syntax checks. Plugin installed as `0.1.0+codex.20260910190518`. See [equipment schedule evidence](Reference/verification/Equipment-schedules.md).

Native map authoring/persistence, automatic header/table detection, unit normalization and plausibility checks, real customer schedule acceptance, and confirmed equipment associations remain unfinished alongside the full engineering/REST/cloud/authenticated Ops/device scope. The full goal remains active.

## Mechanical text extraction and GitHub handoff — 2026-09-10

Added source-anchored mechanical text candidates, asynchronous SDK extraction, native source-page preview and local RFI handoff, plus read-only plugin scan/review commands and strict RFI edits. No automatic physical counts or equipment relationships are inferred.

Recorded snapshot: **241 Swift tests**, Mac/iPad builds and the **29.047-second** synthetic iPad source-preview/RFI test pass. At handoff, **nine wrapper tests**, plugin manifest validation and CI YAML/12 shell-step syntax checks pass. Repository and installed extraction checks preserve source bytes and reject stale references and overwrite. Concurrent edits changed eight production files after the native snapshot; preserve them and validate the final commit. See [mechanical extraction evidence](Reference/verification/Mechanical-text-extraction.md) and [GitHub handoff](REPOSITORY_READY.md).

Full engineering, semantic schedule/geometry association, REST/cloud, authenticated Ops publication and broad device acceptance remain unfinished. The complete application objective remains active.

## Native workbook preparation and local Files acceptance — 2026-09-10

Takeoff XLSX generation now runs through the SDK actor with progress/cancellation, immutable project/drawing snapshots, document-session guards and matching save receipts. Late generation or save-panel callbacks cannot affect a newer document export. Output does not mark the source project saved or alter its review state.

**236 shared tests**, Mac compilation, iPad compilation and two native iPad tests pass: save-panel cancellation/retry (**17.154 seconds**) and actual local Files save (**15.632 seconds**). The saved workbook's five tabs, quantity, mapped material cost and source/history were verified from its actual bytes; the final native screenshot was inspected and build-source hashes match. See `Reference/verification/Workbook-preparation.md`.

Other exporters, large-project/device/provider acceptance, semantic/full engineering methods, local REST/cloud and authenticated Ops publication remain open. The full objective remains active.

## Asynchronous shared SDK service — 2026-09-10

Added a UI-independent `LoadSightServicing` protocol and local actor for existing ingestion, recorded engineering/pricing review and draft document/workbook operations. An owned operation supplies cancellation, bounded AsyncStream progress and a MainActor Combine adapter. Failed drawing batches return no partial archive; source bytes stay local. A 40-line SwiftUI host component compiles and documents document, contractor and markup integration boundaries.

After preserving concurrent module changes, the final combined tree passes **232 shared tests**, the example build, native Mac and unsigned iPad builds. Ten SDK tests cover real PDF ingestion/deduplication, failure, cancellation after work starts, progress/Combine and shared-engine equivalence. Final source hashes match the isolated native build. Plugin SDK guidance is installed as `0.1.0+codex.20260910182859`; CI compiles the example. See `Reference/verification/SDK-service.md`.

The semantic extraction/full-load/derived-takeoff/audit pipeline, local REST/cloud, persistent bookmarks, authenticated publication and complete host acceptance remain open. The worksheet-review method explicitly preserves its partial scope. The full objective remains active.

## Supplier quote evidence and date-aware release review — 2026-09-10

Catalog material mappings now retain supplier quote reference/source, issue and optional expiry instants, and commercial conditions in full mapping history. Native entry and strict plugin edits use the same validated model. Normal pricing review holds release for recorded expired, future or unknown-expiry quotes while preserving draft costs; no quote is invented for legacy/manual pricing. Selecting a new source clears prior quote evidence.

**213 shared tests**, **eight wrapper tests**, Mac compilation, repository/installed four-state plugin checks and quote-field workbook reconciliation pass. Installed plugin is `0.1.0+codex.20260910181642`. The final **83.070-second iPad entry/save/reopen test passes**, its screenshot was inspected, and production source hashes match the build snapshot; see `Reference/verification/Supplier-quote-validity.md`. Supplier retrieval/authenticity, standalone supplier pricing, full engineering/extraction, authenticated Ops workflows and broader device/export acceptance remain open. The full goal remains active.

## Supplied catalog comparison in native editor and plugin — 2026-09-10

The native editor now compares saved material evidence with host-supplied snapshots and clears currency/unit/compatibility confirmation on a new selection. A synthetic iPad acceptance test reviews a $50-to-$75 source change, re-enters the 0.2 conversion, applies and reopens at $15. The shared core distinguishes unchanged, changed, missing, ambiguous, different-source and older-source records.

Added read-only `catalog-compare project.json --catalog supplied-catalog.json` to the repository and installed plugin. Strict input requires explicit cost values or null; versioned JSON preserves differences, candidate availability and edit fingerprints. It never edits or reprices the project. **209 shared tests** and **eight wrapper tests** pass in the combined tree; the repository five-case end-to-end comparison check passes with unchanged source hashes and invalid input rejection. Installed version is `0.1.0+codex.20260910181238`. The regression workflow includes the real comparison command. See `Reference/verification/Catalog-snapshot-comparison.md` for scope.

These are comparisons of supplied local records, not live supplier refresh or quote-validity checks. Full engineering/extraction, quote validity, authenticated Ops synchronization/publication and broader device/export acceptance remain open; the full goal remains active.

## Catalog evidence in workbook exports — 2026-09-10

Added Material costs and Catalog history to the native XLSX export, preserving the existing three sheets. Current/recorded material costs, source identity, unit/currency evidence, mapping status and complete field-level revision history are retained. Unknown costs stay blank, zero stays numeric, UTC timestamps remain sortable, and external text never becomes a formula. The installed/repository plugin now supports `xlsx` with new-output-only protection.

**194 shared tests**, seven wrapper tests, the Mac build, native ZIP/XML source reconciliation and rendered workbook review pass. The synthetic acceptance workbook covers six states, eleven revisions and 198 history rows; its installed-plugin export is byte-identical to the inspected file. Installed version is `0.1.0+codex.20260910180059`; CI adds workbook generation/source checks and passes local YAML/shell syntax validation. See `Reference/verification/Catalog-material-mapping.md`. Live catalog comparison, quote validity, full engineering/extraction, authenticated Ops workflows and broader device/Excel acceptance remain pending. The full goal remains active.

## Catalog mapping plugin workflow — 2026-09-10

Added `catalog-review` and strict `catalog.material.update` requests to the CLI and repository/installed plugin. Review exposes current item costs, saved snapshots, mapping currentness, history and edit fingerprints. Explicit null costs round-trip; typo/missing fields, stale changes and non-USD requests reject without new output. Applying/removing uses the native mapping engine and preserves source files.

**189 shared tests**, six wrapper tests, repository/installed catalog end-to-end checks, the installed **20-operation** regression and manifest/CI syntax checks pass. Installed plugin is `0.1.0+codex.20260910175320`; CI includes the dedicated catalog verifier. See `Reference/verification/Catalog-material-mapping.md`. Workbook provenance, live-catalog comparison and quote validity remain pending with the full engineering/extraction/authenticated-integration objective. No external catalog or accounting action was performed; the full goal remains active.

## Catalog material cost mapping — 2026-09-10

Added explicit Ops material catalog selection in Takeoff, immutable source/cost snapshots, estimator-confirmed USD and purchasing-unit conversion, full authored before/after mapping history, removal retaining entered cost, and stale item/cost protection. The host offers approved Inventory/NonInventory records with unambiguous IDs; selling prices never substitute for purchase costs. Mapping updates material cost only, preserves unknown versus zero, retains quantity/labor/source evidence and reopens QA. Package/JSON and local recovery retain the mapping history.

Eight new mapping tests passed within the initial **165-test** suite. Concurrent document-session/storage-guidance changes were preserved and rechecked: the combined tree passes **182 shared tests**, the Mac build and the final **32.90-second iPad UI test**. Native save/reopen shows $12.50 from the selected $50 snapshot and 0.25 conversion; persisted history, unchanged quantity/unknown labor and all 106 build-source hashes were verified. See `Reference/verification/Catalog-material-mapping.md` for exact evidence and interaction limits. Plugin commands, workbook provenance columns, live-catalog comparison and supplier quote validity remain pending, alongside the full engineering, extraction and authenticated Ops workflows. The full objective remains active.

## Embedded draft recovery — 2026-09-10

The Ops mechanical workspace now checkpoints committed edits in local storage scoped to the current user/account context, restores after restart, and offers explicit keep/discard actions. Original drawings and project history are retained. Atomic writes, per-scope file locking and revision checks reject stale replacement/deletion. Save failures stay visible; users can preserve an unreadable prior draft and explicitly continue with export-only work. Portable export remains separate from local recovery, and delayed export completion cannot clear newer edits.

**157 shared tests**, the rebuilt Mac app and **two selected iPad UI tests** pass. The restart test covers process termination, restoration, keep-and-close, reopening and explicit discard; final screenshots were inspected and 66 build-source hashes verified. CI YAML and shell checks pass locally. See `Reference/verification/Embedded-draft-recovery.md`. Physical-device/power-loss, multi-window UI and export-dialog acceptance remain pending, alongside full engineering methods, extraction, synchronization and authenticated publication. The full objective remains active.

## Explicit Ops customer/job links — 2026-09-10

Added a shared recorded customer/job context with stable UUIDs, optional site identity, full authored before/after history, correction/removal and stale-edit rejection. Native Ops offers explicit choices from unambiguous local customer/job pairs; Overview displays the recorded snapshot and history. Project export retains it. QA reopens, while proposal terms, pricing and external Ops records remain unchanged. This is a local context link, not authenticated billing approval or server-side synchronization.

**145 model tests**, the rebuilt Mac app, installed plugin link checks and its **20-operation** regression pass. The final explicit iOS 26.2 test passed customer/job selection, save/display, Keep editing and explicit project discard. Final screenshot and exact executed test were inspected; relevant build source hashes match the workspace. The repository and installed plugin expose `ops-review` and `ops.context.update`; installed version is `0.1.0+codex.20260910170711`. CI includes the new checks. See `Reference/verification/Ops-project-context.md`. Customer/job synchronization, catalog mapping, authenticated release/billing publication, complete engineering methods and broader device/export acceptance remain unfinished. The full objective remains active.

## GitHub-ready repository files — 2026-09-10

Reviewed the public Ops repository at `e17fec5fca4dfd8042096f7f833db829a0bbcb63` using an isolated bare clone. Added LoadSight setup/architecture/contribution documentation, a portable repository plugin with all 12 skills, a dedicated CI workflow, PR template and shared-scheme ignore exception. The existing native CI now includes the Ops embedding smoke test. No merge, push, deployment or installed-plugin replacement was performed.

**139 Swift tests**, **six portable-wrapper tests**, the **20-operation plugin regression**, plugin manifest validation and CI YAML/shell syntax checks pass locally. The full Ops simulator build and dedicated iOS 26.2 embedding smoke test pass; final evidence is in `Reference/verification/Ops-embedded-workspace.md`. Hosted CI has not run. See `REPOSITORY_READY.md` for file inventory, GitHub provenance and remaining product scope. The full goal remains active.

## Embedded LoadSight workspace in Ops — 2026-09-10

The existing Ops Estimates screen now opens the shared LoadSight editor through a local Swift-package dependency. The host supports new projects, package/JSON import, shared mechanical editing and explicit package/JSON export, with an unsaved-change dismissal guard. The entry respects the existing financial-detail access check. Customer/job binding, catalog mapping and authenticated billing publication remain separate unfinished integration work.

The shared package passes **139 model tests** and the full Ops simulator build passes for arm64 and x86_64. The iCloud-hosted Xcode project waited in macOS file coordination; the successful build used a hashed isolated local source copy. Exact before snapshots preserve unrelated Ops changes. Native smoke-test results and remaining limitations are recorded in `Reference/verification/Ops-embedded-workspace.md`. The complete application objective remains active.

## Change order corrections and history — 2026-09-10

Added native and plugin revision of saved CO drafts with stable identity, unchanged creation metadata, full before/after snapshots, editor/reason/date and stale-edit rejection. Optional values can be cleared without becoming zero. Native history opens complete earlier/later records; Word adds latest-revision metadata and changed fields, source/cost/quantity comparisons and before/after totals. History consistency is validated; authorship remains unauthenticated and status remains Draft.

**139 model tests pass**, the final Mac build passes, and the iOS26.2 runtime test passed actual edit/save/reopen and earlier-snapshot display. Three runtime screenshots and the three-page revised Word sample were visually inspected. The actual native package confirms both scopes and preserved creator/reviser identities. Installed plugin `0.1.0+codex.20260910163616` passed dedicated revision/history/Word/source-preservation checks, including a synthetic +73 to +53 USD revision and rejected stale replay. See `Reference/verification/Change-order-revisions.md`. Full engineering methods, authenticated release, direct Ops integration and broader runtime acceptance remain unfinished; the full objective stays active.

## Change order Word export — 2026-09-10

Added native and plugin export of one saved CO to editable Word. The document preserves original/proposed scope, entitlement/source references, quantity and signed-cost tables, markup basis, tax/bond, schedule terms, missing fields and record identity. Unknown totals remain withheld and every output remains a draft. The shared native Word engine now supports comparison tables while retaining the existing RFI paragraph exporter.

**134 tests pass**, final Mac/iOS builds pass, and installed plugin `0.1.0+codex.20260910162808` passed dedicated export/source-preservation checks and its **20-operation** regression. Both final synthetic CO samples rendered to two pages; all four pages were visually inspected. See `Reference/verification/Change-order-word-export.md`. Native save-dialog interaction is not yet verified. CO corrections/history, complete engineering methods, authenticated release and direct Ops integration remain pending; the full objective stays active.

## Native change order authoring — 2026-09-10

Added Change orders navigation, a complete new-draft form, live cost/missing-field review and saved-record detail. Text-backed inputs preserve invalid entries for correction; blank, zero and credit remain distinct. Original/proposed quantity rows and their sources remain independent of quoted costs. Save calls the shared model and reopens QA. Unsaved dismissal uses explicit Keep editing / Discard draft actions.

**131 model tests pass**, the native Mac build passes, and the iOS26.2 iPad UI test passed actual draft entry, keep-editing, save, close/reopen and record review. The two final screenshots were visually inspected; the saved package independently confirms scope/author persistence and unknown costs. See `Reference/verification/Native-change-orders.md`. Plugin documentation was updated and installed as `0.1.0+codex.20260910162337`. Runtime coverage does not yet include every pricing input or physical-device/Mac interactions. Existing-record CO revisions, CO DOCX, full engineering methods, authenticated release and direct Ops integration remain unfinished; the full goal stays active.

## Change order draft foundation — 2026-09-10

Added shared draft-only change-order records and strict `changeorder.create` / `change-review` plugin commands. The model preserves original/proposed scope, sourced quantities, signed costs and explicit markup basis, with tax/bond/time/exclusion/approval placeholders. Unknown costs withhold totals; credits and known zero remain distinct. Creation preserves the base estimate, records authorship and reopens QA. Duplicate numbers, invalid evidence/dates/categories, overflow, unknown request keys and unsupported approval status fail atomically.

**129 tests pass**, Mac/iOS builds pass, and installed plugin `0.1.0+codex.20260910161940` passed validation and dedicated creation/review/source-preservation checks. See `Reference/verification/Change-order-drafts.md`. CO native authoring, revisions and DOCX are still pending. Full engineering methods, authenticated release and direct Ops integration also remain unfinished; the full objective stays active.

## RFI routing and response planning — 2026-09-10

Added native and structured editing for recipient, sender, request date, required response date and suggested resolution. Blank fields remain unknown; date inputs require valid Gregorian YYYY-MM-DD values. Older edits that omit communication preserve existing values, while explicit replacement/clearing records history and reopens QA. Resolve/reopen retains communication fields, and the native resolution guard includes unsaved routing changes. Word output now includes these fields in before/after history as well as the current record.

**123 tests pass**, Mac/iOS builds pass, and installed plugin `0.1.0+codex.20260910161200` passed validation, its existing **20-operation** workflow and the dedicated `Tools/verify_rfi_communication.py` check. The populated Word export was rendered with bundled LibreOffice and all three pages visually inspected. Source preservation, overwrite rejection, malformed payload rejection and clear-versus-omit behavior are verified. See `Reference/verification/RFI-communication.md`. Native field/save-dialog interaction remains unverified in this pass. No message or reminder is sent. Change orders, full engineering methods, release and direct Ops integration remain unfinished; the full goal stays active.

## Native RFI Word export — 2026-09-10

Added editable selected-RFI DOCX export to LoadSightKit, the native RFI list, Swift CLI and installed GunnAire Ops plugin. Current question/source/impact/response, item links, referenced attachments, export provenance and full before/after recorded RFI history are preserved. Missing text stays Not recorded, missing quantities stay Unknown, attachment payloads are not embedded, and export does not mutate or send the RFI. Optional imported routing/date/suggested-resolution fields are rendered; native editing for those additional fields remains pending.

**118 model tests pass**, final Mac and iOS builds pass, and plugin `0.1.0+codex.20260910160351` passed validation and its existing **20-operation** workflow. Installed DOCX exports passed source-preservation, overwrite-rejection and ZIP/XML checks. Both final DOCX examples were rendered with bundled LibreOffice and all three pages visually inspected: one-page open RFI and two-page resolved RFI including history. See `Reference/verification/RFI-word-export.md` for commands, artifacts and boundaries. Native export-dialog interaction, CO authoring/DOCX, full engineering methods, release and direct Ops integration remain unfinished. The whole original goal remains active.

## Native assembly and room save/revision/reopen — 2026-09-10

**Passed on iOS26.2 QA iPad:** production UI creation of a sourced R10 assembly and100ft² room surface, explicit no-openings confirmation,600Btuh initial result, author/reason revision to75°F and650Btuh, document close, browser reopen, and650Btuh preserved. Final XCUITest: `output/verification/native-ui/20260910T155438429300Z/`. Saved-room and reopened-result screenshots were visually inspected. The copied native package and shared CLI review confirm one assembly, one stable room ID, one revision with600/650Btuh historical results, and current650Btuh.

Added persistent accessibility labels to multiline source/reason inputs. The runner supports selecting one test; the new workflow test handles visible bounds, right-aligned input targets, combined result labels and the native document browser icon. Mac build passed (`output/verification/native-room-mac-build.log`). Prior115 model tests remain the baseline; calculation models and plugin definitions were unchanged. See `Reference/verification/Native-runtime-checks.md` for evidence and exact limits. iOS26.5 creation, physical-device/Mac interaction, drawing/export acceptance, full engineering methods and the overall application/plugin goal remain unfinished.

## Native iPad runtime verification and fixes — 2026-09-10

Added an XCUITest target and repeatable `Tools/run_native_ui_tests.py` runner using isolated QA simulators. Runtime work found and corrected a dynamic-type serialization bug: a .loadsight URL could receive regular JSON instead of a package. The document writer now recognizes the matching dynamic extension, retains explicit JSON support and rejects unsupported types. Debug builds now select the active architecture, avoiding x86_64 app links against arm64 package objects. Native room drafts compare content rather than transient UUIDs and track a loaded/saved baseline, so unchanged forms do not trigger discard prompts. Numeric units remain visible after entry, Calculate dismisses the numeric keyboard, and iPad opening instructions use the document browser.

**Verified on iOS26.2 iPad simulator:** actual project creation and workspace launch; calculation navigation to envelope/room forms; clean reset and dirty draft keep/discard; typed moist-air calculation, visible result units and keyboard dismissal. Final XCUITest and screenshots: `output/verification/native-ui/20260910T151629793290Z/`. Workspace, room-form and final air-result screenshots were visually inspected. **115 model tests passed**, and the Mac build passed; logs are `native-format-tests.log` and `native-runtime-mac-build.log` in output/verification.

**Unresolved:** iOS26.5 simulator document creation still fails during File Provider bookmark resolution (-1005/DocumentManager1), even with correctly formed packages. iOS26.2 success does not prove iOS26.5 or physical-device acceptance. Full room save/revision/reopen, drawing/attachment/export gestures and Mac interactions remain unverified. See `Reference/verification/Native-runtime-checks.md` for exact reproduction, evidence and boundaries. The whole app/engineering/plugin goal remains active.

## Room-case revision workflow — 2026-09-10

Added native revision controls and shared `room.transmission.revise` operation. Revisions keep the existing room ID/count, require an author and reason, retain full before/after input snapshots and reopen QA. The native form loads current case inputs, clears the previous author's name, protects populated drafts with a discard choice and retains draft text when a stale save fails. Preview lookup uses the actual edited ID rather than the last room.

Edit fingerprints cover room inputs, latest revision identity and the whole available assembly catalog, protecting newly selected assemblies as well as original references. QA-only and unrelated-room changes do not invalidate the token. Revision history preserves snapshots of assemblies used by before/after inputs at revision time, allowing historical results to remain stable after live assembly changes. Chain continuity/current-room agreement and both historical calculations are validated. Unknown room-level extensions remain current; replaced nested input arrays are preserved fully in history. This is local consistency checking, not authenticated/tamper-proof approval. `room-review` returns edit fingerprints, raw input/basis history and recomputed beforeResult/afterResult traces. Method details: `Reference/engineering/Room-revision-workflow.md`.

Final verification: **113 XCTest tests passed**, including seven revision tests; Mac and generic iOS Simulator builds passed. Final installed plugin `0.1.0+codex.20260910150013` passed validation and its **20-operation** workflow, including stable room identity, before/after values, original preservation, overwrite rejection, explicit stale-token rejection and continued draft review. Logs: `output/verification/room-revision-tests.log`, `room-revision-mac-build.log`, `room-revision-ios-build.log`, `room-revision-installed-plugin.json`. Native visual/touch acceptance remains unverified following prior CUA transport failures. New threads load the plugin references. Full room/building methods, extraction, release, DOCX and direct Ops integration remain active parts of the original goal.

## Window and door transmission — 2026-09-10

Added optional sourced whole-product U-factors to named room openings and integrated their steady-state transmission with the opaque ledger. Full opening areas are deducted once from opaque area and calculated once as separate U×A×ΔT terms. Per-opening results preserve sign, source and traces. Known-only opening loss/gain remains visible; combined entered-envelope loss/gain/net values are withheld if any opening lacks U, including at zero ΔT. When all listed openings have valid inputs, the combined subtotal is available but still does not establish complete room geometry or full heating/cooling loads.

Native controls expose rating availability, full-product U/source/classification, unrated status and separate opening/envelope traces. No center-of-glass/slab-only values, default U, solar gain or automatic rating-condition correction is substituted. Saved records now use room method v2. Legacy v1 records without U and old result JSON remain readable; adding U under the old method label is rejected. See `Reference/engineering/Opening-transmission-method.md`. Fully glazed/opening-only surfaces, room revision editing, ventilation/infiltration, solar/transient effects and complete room/zone/building methods remain outstanding.

Verification: **106 XCTest tests passed**, including six opening-transmission tests; Mac and generic iOS Simulator builds passed. Final installed plugin `0.1.0+codex.20260910145125` passed validation and a **19-operation** temporary-project check with both unrated and rated room cases, original preservation, overwrite rejection and continued draft review. Logs: `output/verification/opening-transmission-tests.log`, `opening-transmission-mac-build.log`, `opening-transmission-ios-build.log`, `opening-transmission-installed-plugin.json`. Native visual/touch acceptance remains unverified; the prior inspection attempt failed because CUA's native pipe closed. New Codex threads load the plugin update. The whole-application goal remains active.

## Room opaque transmission — 2026-09-10

Connected saved envelope assemblies to native room design cases and source-backed surface/opening ledgers. Each room records indoor design temperature; each surface records gross area, named opening deductions, assembly reference and coincident adjacent design temperature. Numeric inputs retain sources/classifications. The native form requires an explicit no-openings declaration when none are entered. Results expose per-surface U/area/ΔT/Q traces, outward loss, inward gain and signed net outward balance. Previews clear after input or project changes. Records append with author/date/source and assumptions, preserving existing raw provenance and reopening QA.

Room reviews recompute U from referenced assemblies and include those assembly records/results. Assembly changes affect linked room results and invalidate fingerprinted QA. Missing references, duplicate names/identities, nonfinite inputs, unresolved evidence, impossible area deductions and unsupported methods fail validation. Native packages retain rooms and source extensions. This is above-grade opaque steady-state transfer only: windows/doors, ground coupling, ventilation/infiltration, distribution, solar/internal gains, transient effects and complete design loads remain unmodeled, not zero. Room editing/revision history and drawing-derived areas are still outstanding. See `Reference/engineering/Room-transmission-method.md`.

Final verification: **100 XCTest tests passed**, including six room transmission tests; Mac and generic iOS Simulator builds passed. Installed plugin `0.1.0+codex.20260910144647` passed validation and its **18-operation** temporary-project workflow, including new `room.transmission.create` / `room-review`, retained original fixture, overwrite rejection and continued draft state. Evidence is in `output/verification/room-transmission-tests.log`, `room-transmission-mac-build.log`, `room-transmission-ios-build.log`, `room-transmission-installed-plugin.json`. A native app inspection was attempted again; CUA returned “native pipe closed before response,” so visual/touch acceptance is not claimed. Start a new Codex thread to load updated plugin references. The original whole-application goal remains active.

## Source-backed envelope assemblies — 2026-09-10

Added a native envelope assembly editor and shared SDK for complete layer resistances within independent area-weighted heat-flow paths. Every resistance and area fraction retains its source/classification, with assembly author/date/source, construction category, surface-film basis and assumptions. The engine adds no material or film defaults. Path coverage, positive finite resistance, distinct names, required evidence and supported methods are validated. Homogeneous construction requires one path; metal framing and ground/lateral bridge models are outside this method.

Assembly U is the sum of area-weighted path conductances; effective R is its reciprocal. The UI provides path/assembly traces, clears stale previews after edits and saves append-only records while reopening QA. Portable/native imports recompute records and reject invalid or duplicate identities. Existing raw records retain unknown source extensions. These assemblies are not yet linked to room loads. Method basis and boundaries: `Reference/engineering/Envelope-assembly-method.md`.

The installed plugin now supports `assembly.create` and `envelope-review`. Plugin validation passed; final installed version is `0.1.0+codex.20260910144222`. Its 17-operation temporary-project workflow verifies sourced assembly values/traces, prior air/RFI/commercial functions, preservation of the original fixture, overwrite rejection and continued draft review. Start a new Codex thread to load the updated plugin references.

Verification: all **94 XCTest tests passed**, including six new envelope tests; Mac app build and generic iOS Simulator build passed. Evidence: `output/verification/envelope-tests.log`, `envelope-mac-build.log`, `envelope-ios-build.log`, `envelope-installed-plugin.json`. Analytical parallel-path, single-path and ordering cases passed; malformed input, missing evidence, import validation, atomic failure, QA reopening and native package/source-extension persistence are covered. This does not establish physical/native interaction acceptance; the CUA transport was unavailable in the preceding pass. Full load, distribution, extraction, release, DOCX and Ops integration work remains active.

## Connected mixed-air output conditions — 2026-09-10

Saved mixing outputs can now become reusable conditions for downstream mixers/coils without manual re-entry. Native controls save the output with its source process, recursive upstream fingerprint, exact state and full-stream actual CFM; selectors label it calculated and offer an explicit full-stream flow action. Separate branch flow still requires its own basis.

Shared iterative dependency evaluation rejects cycles, missing references, unsupported derivations, altered derived values/flow, and changed upstream evidence. Numeric results and source metadata are checked before downstream calculation. New records append, reopen QA and preserve unknown provenance fields in existing records; no automatic graph revision/repair or approval is implied.

- **88 XCTest tests pass**, including mixing-to-coil mass continuity, package/fingerprint round trips, source-only staleness, cycles, missing references, altered derived values, atomic rejection, eight linked mixing stages, metadata preservation and strict structured derivation.
- Mac and iOS builds pass. Installed plugin `0.1.0+codex.20260910143355` exposes `aircondition.derive`; its 16-operation fixture workflow passed derivation, downstream mass continuity, ADP/humidity traces, source preservation, no overwrite and draft status checks. Plugin validation/reinstall succeeded; new threads load the updated references.
- Native interaction was attempted again and failed with `Sky Computer Use native pipe closed before response`; visual/touch acceptance remains unverified.

[Air dependency method and limits](Reference/engineering/Air-network-method.md) explains fingerprints, validation tolerances, provenance and pending revision/flow/pressure workflows. Evidence: `output/verification/air-network-tests.log`, `air-network-mac-build.log`, `air-network-ios-build.log`, `air-network-installed-plugin.json`; `Tests/LoadSightKitTests/AirNetworkTests.swift`. Skill audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`.

The full original objective remains active: complete room/system loads and distribution methods, physical/manufacturer benchmarks, extraction, authenticated release, DOCX, direct Ops integration and native interaction acceptance are still unfinished.

## Wet-bulb and dew/frost-point source inputs — 2026-09-10 (historical)

The native air-state worksheet now accepts RH, thermodynamic wet bulb or dew/frost point alongside dry bulb and site pressure. It preserves the supplied humidity mode/value and displays its conversion equation. Switching input mode clears the numeric field to prevent unit reinterpretation. Saved records validate the original input against derived RH, retain source/classification/assumptions and reopen QA; legacy RH records remain readable.

- **82 XCTest tests pass**, including 56 primary-reference input cases, freezing/triple-point boundaries, saturation/impossible inputs, source-input persistence in native packages, legacy RH decoding, derived-RH mismatch rejection and strict/exclusive API input choices.
- Mac and iOS builds pass. Installed plugin `0.1.0+codex.20260910142638` accepts either legacy relativeHumidity or nested humidityInput in aircondition.create and returns inputTrace through air-review. Its 15-operation fixture check passed, including both new modes, preserved source files, no overwrite and draft estimate status. Manifest validation/reinstall succeeded; new threads pick up updated references.
- [Humidity-input method and limitations](Reference/engineering/Humidity-input-method.md) records units, equations, thermodynamic/instrument distinctions, phase behavior, source preservation and evidence. Native interaction remains unverified due to the previously observed unavailable computer-use connection; no UI acceptance is claimed from builds.

Evidence: `output/verification/humidity-input-tests.log`, `humidity-input-mac-build.log`, `humidity-input-ios-build.log`, `humidity-input-installed-plugin.json`; `Tests/LoadSightKitTests/HumidityInputTests.swift`; `Tools/generate_humidity_input_fixtures.py`. Skill audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`. Full original scope remains active: weather/coincidence verification, full room/system loads, connected processes, equipment/distribution methods, extraction, authenticated release, DOCX, direct Ops integration and interactive acceptance remain unfinished.

## Coil apparatus dew point and bypass analysis — 2026-09-10 (historical)

Cooling-coil results now include a supplemental apparatus-dew-point analysis at site pressure. The solver finds saturation/process-line intersections and reports temperature, humidity and enthalpy bypass factors with residuals, notes and equations. Native UI displays all candidates. Multiple intersections and near tangency remain explicit; no physical coil is silently selected, and no supplied state or base air-side load is altered to force a solution.

- **78 XCTest tests pass**, including 60 constructed ADP/bypass cases over three pressures, five ADPs and four factors; dry/zero-change/no-intersection cases; tangent/multiple-root behavior; unchanged analytical cooling load; and decoding older result JSON without the optional ADP field.
- Mac and iOS builds pass. The installed plugin `0.1.0+codex.20260910142019` returns candidate analysis through `air-review` and passed the 13-operation fixture workflow with candidate/residual/trace checks, source preservation, no overwrite and draft estimate status. Manifest validation and reinstall succeeded.
- Native interaction was attempted again and failed with `Sky Computer Use native pipe closed before response`; visual/touch acceptance remains unverified.

[ADP method, tolerances, sources and limitations](Reference/engineering/Coil-ADP-method.md) distinguishes the geometric inference from physical coil validation, frost/defrost, manufacturer capacity selection and approved engineering decisions. It has a separate method identifier from the existing air-side load. Full original scope remains active, including complete load/distribution methods, source benchmarks, connected processes, extraction, authenticated release, DOCX, direct Ops integration and interactive acceptance.

Evidence: `output/verification/adp-tests.log`, `adp-mac-build.log`, `adp-ios-build.log`, `adp-installed-plugin.json`; `Tests/LoadSightKitTests/CoilADPTests.swift`. Skill audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`. New Codex threads pick up the updated plugin reference.

## Mixed-air and cooling-coil process worksheets — 2026-09-10 (historical)

The native Calculations workspace now offers air processes using saved source conditions. Mixing converts each actual inlet CFM to dry-air mass before conserving humidity ratio and enthalpy. Cooling reports air-side total/sensible/latent load, SHR and water removal from inlet/outlet conditions. Equation traces show substitutions, units and assumptions. Invalid pressure/flow, heating/humidifying cooling cases and fog-producing mixtures fail explicitly.

Saved process records retain source condition IDs, name, author, date, method, actual flow and classification; native/JSON persistence recomputes results and validates references. Saving reopens QA. Source states are recalculated rather than trusting decoded derived properties. Mixed results remain process outputs; reusable derived-state graphs are still outstanding.

- **74 XCTest tests pass**, including analytical mass/energy/moisture balances, dry/zero-load coils, invalid input/fog cases, canonical-state recomputation, strict structured request types, source preservation and native package round trips. Mac and iOS builds pass; UI/touch acceptance remains unverified.
- The installed plugin `0.1.0+codex.20260910141235` now exposes `aircondition.create`, `airprocess.create` and read-only `air-review`, including results, provenance, assumptions and traces. The final installed wrapper passed 13 temporary-fixture operations, preserving source files, rejecting overwrite and retaining draft estimate status. Plugin validation and reinstall succeeded; new Codex threads pick up the update.
- [Method and limits](Reference/engineering/Air-process-method.md) records the property basis, sensible/latent convention, analytical fixtures and primary-source cross-check. Coil output is air-side heat removal, not refrigerant duty or manufacturer capacity. ADP/bypass factor, fog water balance, connected process graphs, heating/humidification, complete room/system design loads and equipment selection remain unfinished.

Evidence: `output/verification/air-process-tests.log`, `air-process-mac-build.log`, `air-process-ios-build.log`, `air-process-installed-plugin.json`; `Tools/verify_plugin_edits.py` now exercises 13 operations. Skill audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`. The full original application/plugin objective remains active, including extraction, complete engineering, authenticated release, DOCX, direct Ops integration and interactive acceptance.

## Native psychrometric state calculator — 2026-09-10 (historical)

The Calculations workspace now includes a pressure-aware moist-air calculator alongside the existing sensible-air worksheet. It accepts dry bulb, RH and absolute site pressure, with IP defaults, explicit input classifications, humidity ratio, dew/frost point, thermodynamic wet bulb, SI/IP enthalpy, specific volume, equations and substitutions. Zero humidity remains zero; unavailable roots/undefined dew points are explained.

Saved conditions retain name, author, source, timestamp, method, input classifications and assumptions. The SDK recomputes values from saved inputs, rejects unsupported methods and unresolved RFI-required inputs, retains records in native packages/JSON, and reopens QA when saving. It does not infer project weather or feed room/equipment loads yet.

- **68 XCTest tests pass**, including a 160-state comparison against retained PsychroLib source, dry/saturated/invalid inputs, pressure effects, source retention, unsupported methods, QA reopening and native package round trips. Mac and iOS builds pass. This is implementation parity evidence, not full engineering certification.
- Native interaction was attempted again, but computer use returned `Sky Computer Use native pipe closed before response`. UI, touch and accessibility acceptance remain unverified.
- [Method, equations, provenance and limits](Reference/engineering/Psychrometric-method.md) describes the domain, phase behavior, units and enthalpy datums. Skill guidance drove IP defaults, classification, assumptions and trace details. Audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`.

Evidence: `output/verification/psychrometric-tests.log`, `psychrometric-mac-build.log`, `psychrometric-ios-build.log`; `Tests/LoadSightKitTests/PsychrometricTests.swift` and its 160-state fixture. The full application goal remains active: complete load/distribution/coil methods, engineering benchmarks, extraction, final release/authentication, DOCX, direct Ops integration and interactive acceptance are still outstanding. The installed plugin has not been changed in this pass.

## Native takeoff XLSX export — 2026-09-10 (historical)

The native Takeoff toolbar now exports a three-sheet XLSX snapshot through LoadSightKit: Takeoff, RFIs and Review. The CLI supports `loadsight xlsx project.json new-file.xlsx` and refuses to overwrite existing files. Unknown quantities stay blank, zero stays numeric, source strings remain literal (including formula-like text), supported dates use numeric date cells, and existing source/basis/provenance fields are retained. Frozen headers/IDs, filters and wrapped text make the records reviewable. This is a draft snapshot, not a live pricing workbook or bid release.

- **63 XCTest tests pass**, including zero/null handling, literal formula-like text, typed dates and rejection of unrepresentable/oversized source fields. Mac and iOS Simulator builds pass.
- The actual native-generated dental workbook passed ZIP CRC checks, XML parsing, artifact-tool import and rendering, and independent read-only comparison of all source fields across 46 takeoff rows, 12 RFIs and 12 QA rows. Representative layouts on all three sheets were visually inspected; whole-number formatting was corrected after inspection. The inherited dental evidence was exported, not newly verified against drawings.
- The exporter runs entirely in Swift on Mac/iPad. Spreadsheet skill guidance informed styling, types and verification; artifact-tool was used to inspect/render the actual native file without re-exporting it. OpenXML structure follows Microsoft's SpreadsheetML documentation. Native Excel and file-dialog interaction remain unverified.
- Cells above Excel's text limit or records exceeding the supported row-height estimate fail explicitly instead of truncating. The full objective remains active: engineering/extraction, final release/authenticated roles, DOCX, live cost workbook formulas, direct Ops handoff and native interaction acceptance remain unfinished. The installed plugin wrapper does not yet expose XLSX export.

Evidence: `output/xlsx/Dental-Takeoff.xlsx`, `output/verification/xlsx-tests.log`, `xlsx-mac-build.log`, `xlsx-ios-build.log`, `xlsx-integrity-check.log`, `xlsx-artifact-check.log`; representative renders in `tmp/xlsx/`. Skill audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`.

## Plugin workflow parity — 2026-09-10 (historical)

The installed GunnAire Ops plugin now exposes proposal.update, item.review, qa.review and attachment.add alongside the five existing RFI/commercial operations. Requests use the same SDK provenance, type validation, byte-integrity, stale-review and QA-invalidation rules as the native app. The capability reference has been rewritten to distinguish current functionality from the full unfinished scope.

- **60 XCTest tests pass**, including rejection of malformed request types, unsupported quantity status and invalid attachment base64. The final installed version `0.1.0+codex.20260910135400` passed a nine-operation temporary-fixture workflow, preserving the original, rejecting output overwrite and retaining draft status. Mac and iOS builds pass.
- QA author is the actual recorded reviewer; documentation explicitly requires real review evidence and prohibits treating tool availability or passing software tests as project signoff. No proposal is sent, purchased or published to Ops.
- An earlier integration attempt used a cache path removed during plugin reinstall; the final installed path was tested successfully after reinstall completed. No production project was changed.

Evidence: `output/verification/plugin-parity-tests.log`, `plugin-parity-installed.json`, `plugin-parity-ios-build.log`, `plugin-parity-mac-build.log`; `Tools/verify_plugin_edits.py` now exercises nine operations.

The full application objective remains active. Engineering/extraction, final release/authenticated roles, DOCX/XLSX, direct Ops handoff and native interaction acceptance remain unfinished.

## Portable attachments — 2026-09-10 (historical)

The native Attachments workspace imports supporting files with recorder/source information and an optional existing RFI link, lists their SHA-256 fingerprints and provenance, and exports original bytes through native file export. Identical content is stored once while additional filenames/source references are retained. An exact repeated import is a no-op.

- Shared `addAttachment` and `attachments` APIs validate content fingerprints and preserve original binary data. Project validation rejects changed attachment bytes. Invalid links, missing provenance and unsafe multi-component filenames fail atomically. New evidence reopens QA without resolving RFIs or changing costs.
- **59 XCTest tests pass**, including three attachment tests covering deduplication/provenance, corruption and invalid-input rejection, and exact binary persistence in both JSON and native package round trips. Mac and iOS builds pass. Import/export-dialog interaction remains unverified.
- This version embeds attachments in project JSON, including inside `.loadsight` packages, with a 64 MB per-file limit. Streaming/separate-file storage for large sets, attachment preview, removal/version replacement and outgoing proposal/RFI bundles remain unfinished. File references in proposal terms remain separate from retained files.

Evidence: `output/verification/attachment-tests.log`, `attachment-ios-build.log`, `attachment-mac-build.log`; `Tests/LoadSightKitTests/ProjectAttachmentTests.swift`.

## Proposal details editor — 2026-09-10 (historical)

The Estimate screen now opens a dedicated Proposal details editor for address, scope of work, inclusions/exclusions, assumptions, alternate acceptance conditions, bonds, schedule/access, lead times, validity, addenda basis and attachment references. Supplied details appear in draft PDF output. Blank fields remain unknown; no default agreement or price is inferred.

- `updateProposalDetails` records author, source/reason, date and before/after terms, preserves unrelated values, and reopens QA. Proposal terms also participate in the existing semantic review fingerprint. Narrative alternates and bond terms do not silently add costs.
- **56 XCTest tests pass**, including term/history persistence, invalid input rejection, cost preservation and PDF text coverage of all fields. A three-page explicitly fictional fixture PDF was rendered and visually inspected. Mac and iOS builds pass; native editor interaction remains unverified.
- Attachment entries are references only. Actual attachment storage, priced alternate selection, full final proposal approval/comparison and RFI/CO document templates remain unfinished.

Evidence: `output/verification/proposal-details-tests.log`, `proposal-details-ios-build.log`, `proposal-details-mac-build.log`; temporary fixture PDF and page renders in `tmp/pdfs/proposal-details-fixture*`.

## Native draft PDF and binary-collision fix — 2026-09-10 (historical)

The Estimate screen now exports a draft proposal PDF through native file export. `DraftProposal.pdf` uses CoreText/CoreGraphics on Mac and iOS; the CLI supports `loadsight draft-pdf project.json new-output.pdf`. The draft carries project/customer/estimator, supplied scope and terms, commercial assumptions, all review blockers, drawing basis, item quantities/scope/lifecycle/evidence, RFIs and the project review fingerprint. Missing values stay explicit and no final selling price is issued.

- Generated `output/pdf/Dental-Office-Draft-Proposal.pdf` from the recovered dental project. All 12 final pages were rendered and visually inspected after correcting record/heading pagination. This is a draft of recorded evidence, not fresh verification of dental drawing quantities.
- **53 XCTest tests pass**, including PDF parsing for all item/RFI identities, draft/footer page labels and long-record nontruncation. Mac and iOS builds succeed. Native export-button/file-dialog interaction remains unverified.
- Found and fixed a real case-insensitive filesystem collision: Swift products `LoadSight` and `loadsight` wrote to the same binary path. The desktop build product is now `LoadSightDesktop`; the app bundle and visible name remain LoadSight. A clean rebuild plus direct CLI validation after Mac bundling proves the CLI is no longer replaced by the app. The installed plugin workflow was rechecked after the fix.

Evidence: `output/verification/pdf-tests.log`, `pdf-ios-build.log`, `pdf-mac-build.log`, `cli-after-mac-build.log`, `plugin-after-binary-fix.json`; temporary rendered review pages under `tmp/pdfs/`.

Remaining exports: full proposal field editor, final proposal comparison/release, formal RFI/CO DOCX and PDF, XLSX and integration of those artifacts into project history. Draft PDF export alone does not complete the document system or full app.

## Item scope and quantity-review update — 2026-09-10 (historical)

Each native takeoff row now has a Review action for Base/Allowance/Hold/Excluded scope and documented quantity status. The review records reviewer, evidence, prior/current row snapshots and written allowance basis without altering quantity or drawing geometry. Saving reopens QA. Unknown quantities cannot be approved; an approved allowance requires Allowance scope and written basis.

- `ProjectDocument.reviewItem` is shared SDK functionality. A retained quantity-review snapshot binds quantity, unit, source, basis, lifecycle, scope, description/category and allowance decision. Later changes to these values block estimate readiness until reviewed again. Rate-only edits preserve the quantity review while still reopening commercial QA.
- Native review history shows the prior decisions and supporting evidence. An item review does not resolve RFIs, approve procurement, authenticate identity, or release a bid by itself.
- **51 XCTest tests pass**, including three new tests for review persistence/QA invalidation, stale quantity/source evidence, cost-only edits, unknown quantities and written allowances. Mac and iOS builds pass. Native visual/touch acceptance remains unverified.

Evidence: `output/verification/item-review-tests.log`, `item-review-ios-build.log`, `item-review-mac-build.log`; `Tests/LoadSightKitTests/ItemReviewTests.swift`.

Next major work remains document generation and release comparison, full load/distribution calculations, deeper drawing extraction, authenticated Ops integration and interactive acceptance. Full original scope remains active.

## QA checklist implementation update — 2026-09-10 (historical)

The native QA screen now exposes all required checks with recorded reviewer, evidence, review history and explicit reopening. Managed reviews bind to a SHA-256 fingerprint of semantic project state. Pricing review blocks completed checks whose fingerprint no longer matches. Completing another check does not stale independent checks, but changing an underlying check reopens final signoff.

- A new final QA-12 signoff requires all eleven preceding checks to have current version-bound reviews and a reviewer name different from the responsible estimator. It also binds the preceding checklist state, detecting later changes to review evidence. Names are locally recorded, not authenticated identities.
- Documented legacy checks retain compatibility in legacy readiness assessment and are labelled unversioned in the UI. They must be reviewed against the current state before the new final-signoff API accepts them. This does not retrospectively authenticate old approvals.
- The semantic fingerprint retains source references/hashes and estimate content but excludes portable drawing-byte representation and review history. Native/CLI drawing validation separately checks original bytes. Package/JSON round trips with an imported drawing retain the review state.
- **48 XCTest tests pass**, including four QA workflow tests for independent review, stale data/checklist changes, reopening history, atomic failures and persistence. Mac and iOS builds pass. UI interaction remains unverified due to the previously recorded native connection failure.

Evidence: `output/verification/qa-tests.log`, `qa-ios-build.log`, `qa-mac-build.log`; `Tests/LoadSightKitTests/QAWorkflowTests.swift`.

Remaining: authenticated roles/signoff, exported-proposal comparison and final release artifacts, item quantity/scope approval workflow, full engineering/extraction and direct Ops handoff. This is a checklist implementation, not proof of full app completion or engineering correctness.

## Installed-plugin workflow update — 2026-09-10 (historical)

The installed GunnAire Ops plugin now exposes RFI create/edit/resolve/reopen and commercial assumption updates through structured JSON requests. `loadsight apply project.json request.json new-project.json` and the Python wrapper use the same Swift lifecycle APIs as the native screens. Output is a new self-contained JSON project; existing files and symlinks cannot be replaced. The plugin still requires the local Swift workspace and does not directly publish to the Ops database.

- `ProjectEditing.apply` rejects unsupported operations, unknown keys, missing required fields and invalid lifecycle transitions. Authorship, answer sources and commercial change reasons follow the same native requirements; history and QA invalidation are preserved.
- Drawing source integrity, markup quantities and source-page bounds are now validated in the shared SDK. Native document checks delegate to that same code; CLI validate/review/csv/apply validate portable drawing evidence before proceeding.
- **44 XCTest tests pass**. Three new command tests cover the full action sequence, invalid requests, output round trip, overwrite/symlink rejection and cleanup. The installed plugin's five-operation integration test on temporary copies in the actual workspace passed, preserving the original fixture and withholding a selling price. iOS and Mac builds pass.
- Installed version: `0.1.0+codex.20260910133522`. Manifest validation passed. New Codex threads load the updated plugin references. Exact request examples are in the plugin's `references/project-edits.md`.

Evidence: `output/verification/plugin-edit-tests.log`, `installed-plugin-edits.json`, `plugin-edit-ios-build.log`, `plugin-edit-mac-build.log`; reproducible installed-wrapper check in `Tools/verify_plugin_edits.py`.

Limitations: CLI input is self-contained JSON exported from the native app, not a `.loadsight` package directory. This does not send RFIs, generate formal documents, authenticate approvals, or publish estimates. Native visual/touch acceptance and the full remaining scope below are still open.

## Commercial-input implementation update — 2026-09-10 (historical)

The native Estimate screen now edits project name, customer, responsible estimator, proposal terms, loaded labor rate, markup on cost, dollar tax allowance, other job costs and contingency. Blank numeric entries remain unknown; deliberate zero remains zero. Cost review distinguishes known direct cost from complete estimated cost and withholds selling price while blockers remain. Calculation errors are displayed.

- `ProjectDocument.updateCommercialInputs` provides atomic partial updates, preserves extension fields, records author/source/time with before/after snapshots, and reopens QA after actual changes. No-op saves preserve review state. This is entered-assumption history, not authenticated commercial approval.
- Numeric values use round-trip string formatting in both commercial and takeoff editors to avoid silently rounding precise values when saving.
- **41 XCTest tests pass**, including three new commercial-input cases for unknown/zero semantics, preservation, history, invalid inputs and QA. Mac and iOS simulator builds pass; visual acceptance remains unverified because native UI access failed in the preceding pass.

Evidence: `output/verification/commercial-tests.log`, `commercial-ios-build.log`, `commercial-mac-build.log`; `Tests/LoadSightKitTests/CommercialInputTests.swift`.

Remaining commercial work includes item scope/allowance editing, authenticated/versioned QA and estimator approval, supplier provenance, alternates/bonds/lead times, proposal documents and direct Ops handoff. Full application and plugin scope remains active.

## RFI workflow implementation update — 2026-09-10 (historical)

The native RFI register now supports creating and editing open questions, linking affected takeoff items, recording a sourced answer and respondent, and reopening a resolved question with a reason. Search includes questions, sources and responses; the register can filter to open questions. The editor displays prior changes and retained answer evidence. Unsaved question edits must be saved before recording a resolution.

- Shared `ProjectDocument` APIs provide the same workflow for hosts: `saveRFI`, `resolveRFI`, and `reopenRFI`. Each successful action records author, time, before/after snapshots and reason, then reopens QA. Resolving an RFI never changes quantities, scope or prices automatically.
- Existing dental RFIs retain original fields and identifiers when adopted into the workflow. Managed records require source evidence and must match the latest history snapshot. Invalid transitions and missing answer provenance fail atomically. This is a local consistency/history mechanism, not cryptographic tamper protection or authenticated approval.
- Deleted takeoff items leave their RFI links visible as historical identities. Saving revised links requires existing takeoff identities. JSON and native package round trips retain answers and history.
- **38 XCTest tests pass**, including five RFI workflow cases. Mac bundle and iOS simulator app builds succeed. Native UI inspection was retried but still fails with `Sky Computer Use native pipe closed before response`; no interactive acceptance is claimed.

Evidence: `output/verification/rfi-tests.log`, `rfi-ios-build.log`, `rfi-mac-build.log`; `Tests/LoadSightKitTests/RFIWorkflowTests.swift`.

Next priority: complete editable commercial/QA workflow, RFI/CO document generation and plugin workflow exposure, alongside interactive acceptance when native UI access becomes available. Full load/distribution engineering, extraction, direct Ops integration and the remaining requirements below remain active.

## Drawing-markup implementation update — 2026-09-10 (historical)

Native drawing controls now support physical-object counts with repeated-view evidence, lifecycle/system/size tagging, bounded view calibration, a second known-dimension check, and centerline route capture. Markups persist in project JSON and `.loadsight` packages. **33 XCTest tests pass**, including eight markup cases; Mac and iOS simulator builds succeed. These verify models and compilation; visual, Pencil and touch acceptance remain unverified because the computer-use connection has been unavailable.

- Multiple anchors linked to one physical object produce one EA. Different lifecycle/system/size descriptors cannot silently merge. Existing-to-remain items default to excluded scope.
- Route LF is recomputed from saved geometry. Measurement requires an independent scale check within a 2% geometric tolerance and stays within one calibrated region. Verticals, fittings and waste remain separate; measured rows retain draft status and unknown prices.
- Saved actions and undo events retain evidence and authors. The calibration checker is recorded separately from the original estimator. Geometry-derived quantities cannot be overridden through the estimate editor; changes reopen QA. Pricing and document loading reject inconsistent derived rows, and document loading/saving checks source-page bounds.
- PDFKit preview overlays leave original drawing bytes unchanged. Inspect mode releases the capture gesture for native navigation. Interactive usability and annotation alignment still require acceptance testing on Mac and iPad.

Evidence: `output/verification/markup-tests.log`, `ios-app-build.log`, `mac-bundle-build.log`; `Tests/LoadSightKitTests/MarkupTests.swift`.

Next priority: interactive drawing acceptance, editable RFI/pricing workflow, then the remaining original requirements below. The installed plugin retains its intake/review/export interface; this pass adds shared-engine markup validation but no new plugin markup command. The full objective remains active.

## Drawing-intake implementation update — 2026-09-10 (historical)

The prior turn was progress. This continuation adds `LoadSightIngest`, native drawing import/viewing, portable `.loadsight` packages, and an iOS Xcode application target. **25 XCTest tests pass** on arm64 macOS, including eight drawing-intake/persistence cases. Initial and incremental iOS simulator app builds succeed; the Mac app bundle is rebuilt. These are build and model tests, not visual/touch acceptance.

- Original PDF/image bytes are retained and verified by SHA-256. PDF text anchors keep page coordinates; raster PDFs and image frames use local Vision OCR. JPEG/PNG/HEIC/TIFF use ImageIO with EXIF orientation normalization and a 6000-pixel display cap. Full-page OCR is an explicit option for PDFs with mixed content; default extraction warns that image-only regions on text-bearing pages were not OCR-reviewed.
- The viewer uses native PDFKit on Mac and iPad, with source/page controls and a text-evidence panel. No physical scale is inferred from imported coordinates. Symbol extraction, vector path analysis, measurement/count overlays, auto-perspective correction and automatic title-block confirmation remain unfinished.
- Package and self-contained JSON round trips preserve original bytes and text evidence. Package open rejects missing, changed and unindexed originals. A repeated file fingerprint is idempotent; new sources reopen QA. A matching legacy source fingerprint/page links the existing sheet record rather than creating duplicate pages.
- Real dental PDF import matches prior source hash `427c43073a9b567bf532e2f7f6a4458a3b07c765f646aa0228e16b399f0d0797`. It yields five pages with 426/214/275/120/38 native text anchors. The five page renders were inspected for page identity and layout; this is not a fresh complete quantity or specification audit. The M101 reference to M600 is retained as a candidate rather than silently changed to M601.
- `Native/LoadSight.xcodeproj` builds the actual iOS app using the shared `LoadSightUI` package. `Tools/build_mac.py` registers the `.loadsight` package type in the local Mac bundle. Device signing, distribution, simulator interaction tests and physical-iPad acceptance remain outstanding.
- Plugin wrapper supports `ingest drawing.pdf` and emits the source/page/text index without base64 source bytes. Its capability reference now distinguishes intake from autonomous geometry/symbol interpretation.

Evidence: `output/verification/drawing-intake-tests.log`, `ios-app-build.log`, `ios-ui-build.log`, `mac-app-build.log`, `dental-drawing-index.json`; controlled vector/raster/rotated fixtures in `Tests/LoadSightKitTests/Fixtures/` with reproducible generator `Tools/create_drawing_fixture.py`.

Next priority: native count/calibration/route overlays and durable takeoff linkage, then interactive iPad acceptance, full editable RFI/pricing workflow and the remaining original requirements below. The full objective remains active.

## Initial implementation and evidence (historical baseline)

| Requirement | Current evidence | Status |
| --- | --- | --- |
| Shared deterministic Swift package, macOS 14 / iOS 17 minimum | `Package.swift`; `LoadSightCore`, `LoadSightCalc`, `LoadSightTakeoff`, `LoadSightKit` | Initial implemented modules compile on macOS |
| Legacy takeoff continuity | Lossless JSON tree, version validation, atomic edits, fixture round-trip test preserving all fields | Implemented for schema 1 |
| Unknown quantities and prices remain unknown | Pricing tests cover null vs intentional zero; complete costs do not imply release | Implemented |
| Lifecycle and repeated-view evidence | Entire device/marker ledger retained; dental fixtures retain 6 S1, 17 S2, 21 R1, 8 reused VAV and 8 thermostat records | Preservation tested; new extraction/dedup workflow outstanding |
| Per-view calibration and route lengths | Bounded scale regions, independent reference check, polyline length; tests reject view crossing | Core implemented; touch editor and persisted overlays outstanding |
| Duct surface area and velocity | Rectangular/round bare surface, rectangular velocity; golden tests | Elementary geometry implemented; fittings, stretch-out, assemblies and purchase rounding outstanding |
| Engineering arithmetic | UA, assembly U, sensible/latent/total air, SHR, ACH, zone OA with Ez, water flow, gas demand, coincident block peak | Elementary formulas tested; full load model/methods outstanding |
| Cost build-up and release checks | Material-only waste, labor, subcontract/other, markup; 12 required QA IDs, RFI/hold checks, explicit price provenance | Initial engine tested; approval identity/version workflow outstanding |
| Exports | Lossless project JSON; escaped CSV | Implemented through SDK/CLI; XLSX/PDF/DOCX outstanding |
| Native UI | `LoadSightUI`, `LoadSightApp`; document opening/saving, overview, takeoff edit sheet, read-only source/requirement/RFI registers, sensible-air worksheet | macOS build passes; UI interaction unverified |
| Local Mac app | `python3 Tools/build_mac.py` produces `output/LoadSight.app`; launch command accepted | UI observation failed because computer-use native pipe is unavailable; do not claim visual acceptance |
| Personal Codex plugin | `~/plugins/gunnaire-ops`; marketplace entry; 11 requested skills + recovered orchestrator; shared-engine CLI wrapper | Created; manifest and individual skill validation run |
| GunnAire Ops integration | Existing `Estimate.swift` inspected; isolated package under Ops repository avoids changing active billing work | Direct native entry point, reviewed estimate handoff and role checks outstanding |

Initial `swift test --scratch-path /tmp/gunnaire-loadsight-build`: **17 XCTest tests, zero failures** on arm64 macOS. The separate Swift Testing footer reports zero tests because these tests use XCTest; it is not the executed-test count. Package and native Mac executable builds pass. Plugin CLI review of the recovered dental project reports 15 holds, 12 open/undocumented RFIs, 28 included rows missing costs, and no selling price.

## Remaining required work — preserve full scope

1. Native drawing ingestion: PDFKit vector/text + page-coordinate extraction, Vision OCR for scans/photos, rotation/perspective correction, sheet/title/revision/addenda index, image/PDF/HEIC/TIFF/CAD-export support; confidence and review overlays. Test the real five mechanical sheets and controlled image/vector/mixed-scale fixtures.
2. iPad-first viewer: pan/zoom/Pencil/touch, count and lifecycle tagging, per-region calibration and independent validation, polyline routes split by size/material/system/status, elevations/fittings, undo, source-note inspection, durable offline edits and native Files sharing. Build and test a proper iOS Xcode target.
3. Full extraction model: spaces, boundaries, envelope, orientation, equipment schedules, dimensions/CFM/ESP/capacity/electrical-coordination/weight, plan-to-schedule and duplicate-view reconciliation, materials/definitions/specification obligations and assembly expansion.
4. Load engine: design-condition/assumptions log, room/zone/system/coil loads, internal/solar/infiltration/ventilation/duct gains, full psychrometrics including wet bulb/dew point/ADP, design-condition equipment performance, peak vs block, ranges, and validation against independently sourced fixtures. Keep ACCA J/S/D/N methods distinct; do not claim certification from basic equations. Manual M was explicitly removed by the user; Manual C needs verified identity.
5. Distribution and compliance: equal-friction/static-regain sizing, pressure/fitting loss, fan/pump laws, hydronic/steam/refrigerant conceptual checks, source-backed fuel-gas sizing and combustion/venting, weight/clearance coordination, jurisdiction/edition/local amendments, California overlay. Plumbing and electrical trade takeoffs stay excluded unless explicitly included.
6. Audit workflow: extracted vs calculated requirement, delta/percent/verdict/action, insufficient-data state, linked evidence, RFI/CO generation, documented answers, revision deltas, append-only correction trail, approval invalidation across all affected records.
7. Commercial workflow: supplier/labor entry and provenance, allowances/alternates/taxes/bonds/contingency/lead times, complete proposal editor, independent estimator signoff, XLSX quantities, PDF proposals, DOCX RFI and CO, templates and rendered-layout verification. No invented rates or final zero-dollar bid.
8. `.loadsight` project package with original drawings, extracted/calculation/takeoff/audit/document/assumption/overlay artifacts; migration, recovery, conflict handling, bookmarks/sandbox access, cancellation and background progress.
9. SDK service protocol, async ingest/extract/calculate/takeoff/audit/draft methods, AsyncStream and Combine progress, optional LLM bridge and opt-in cloud processing, local REST service, examples for document/estimating/markup hosts.
10. GunnAire Ops app entry point, company/role-aware project linkage, reviewed estimate and change-order handoff retaining identity/source/approval evidence, idempotent import and failure recovery. Coordinate with ongoing Ops source changes before touching shared files. No direct accounting mutations are currently implemented by this plugin.
11. Full application acceptance on Mac and iPad, real drawing fixture verification, document export rendering, plugin behavioral checks, packaging/distribution, and requirement-by-requirement completion audit.

The latest implementation update above supersedes earlier next-step plans; this remaining-work list retains the full original scope, including capabilities now partially implemented.

## Commands

```sh
swift test --scratch-path /tmp/gunnaire-loadsight-build
swift run --scratch-path /tmp/gunnaire-loadsight-build loadsight review Reference/project/Dental_Office_Seed.json
python3 Tools/build_mac.py
python3 ~/plugins/gunnaire-ops/scripts/loadsight.py review Reference/project/Dental_Office_Seed.json
```

Audit: `~/.codex/skill-audits/skill-usage.jsonl`. Skill guidance changed the implementation by preserving missing values and evidence, separating trade/lifecycle status from quantities, and invalidating QA after changes.
