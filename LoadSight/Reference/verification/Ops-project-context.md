# Explicit Ops customer and job context

The shared model stores a selected Ops customer and optional job snapshot with UUID identities, names, customer address, job site and optional service-location ID. A job must identify the same customer. Missing site data stays blank and is never substituted with the billing address. The native Ops host constructs choices only from unambiguous current local customer/job IDs with a resolved matching relationship; it does not mutate those records.

Linking, correcting, reaffirming and removing require recorded author/reason plus the current context edit fingerprint. Each event stores full before/after snapshots and timestamp; a removal retains prior context. History validates the complete chain and current-state agreement. QA reopens, while commercial inputs, proposal customer/address and takeoff items stay unchanged. Authors are recorded text, not authentication. Imported link data does not authorize a backend action or prove live business access.

The native Overview offers Review Ops link, current snapshot, explicit customer/job choice, source-independent author/reason, correction/removal and history. Unsaved editor selections have a discard guard. The embedded host also guards unsaved project closure; the project must be exported to retain edits. The standalone app can review/remove a recorded link; it receives no live Ops selection list.

CLI `ops-review` returns context, history, fingerprint and authority limitation. Plugin `ops.context.update` requires an explicit complete context or null for removal; unknown keys and mismatched jobs fail atomically. Optional job and service-location values are emitted as explicit null for round-trip API use. Details are in `Plugins/gunnaire-ops/references/ops-project-context.md` relative to the repository root.

Verification:

- 145 shared tests pass in `output/verification/ops-context-tests-final.log`. Six new tests cover full link/correction/removal history, unchanged commercial data, customer/job mismatch and missing-evidence rejection, stale/no-op tokens, broken history/date/current-state rejection, package/JSON round trips and strict structured edit fields.
- Repository and installed plugin dedicated checks passed: `ops-context-plugin/summary.json`, `ops-context-installed-final/summary.json`. These verify real CLI apply/read behavior, mismatch/stale rejection, unlink history and unchanged source. Installed plugin version is `0.1.0+codex.20260910170711`.
- The installed plugin's existing 20-operation regression passed in `ops-context-installed-regression.json`.

The final selected native test passed on the iOS 26.2 QA iPad in `ops-context-native/tests.json`, with its full build/test log, source hashes and screenshot. It selects the synthetic customer/job, records author/reason, saves and displays both identities, tests Keep editing on the unsaved-project guard, and returns to Ops only after Discard. The screenshot was visually inspected; 64 relevant source files in the isolated build copy match the workspace. Project package/JSON persistence is established by model round-trip tests, not a native export-dialog test.

An initial class-level test selection ran only the previously discovered open/close method despite compiling the new method; it was not accepted as link-workflow evidence. Explicit method selection then exercised the new flow. Initial assertions used separate value labels and failed; the observed accessibility tree uses combined `Customer, …` and `Job, …` labels. The test now waits for the sheet dismissal and checks those actual labels. No saved-data defect was established by these assertion failures. Full customer/job synchronization, server-side tenant authorization, catalog mapping, billing publication, full engineering methods and broader physical-device acceptance remain separate work. This feature does not complete the overall product.

The native Mac app was rebuilt successfully (`ops-context-mac-build.log`). Both CI workflow YAML files and embedded shell scripts pass syntax checks; all six portable wrapper boundary tests still pass.
