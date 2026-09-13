# Schedule numeric review — 2026-09-10

The shared reader now returns separate scalar interpretations keyed by unchanged row IDs. Native review shows the numeric result and a disclosure for factor/offset and source guidance beside the literal cell. The plugin's existing schedule commands expose the same output. See [method and exact supported units](../engineering/Schedule-numeric-units.md).

## Verified

- 274 shared tests pass, including five new conversion/parsing/domain/original-PDF tests. The absolute-zero Fahrenheit boundary is included to prevent floating-point rounding from rejecting a valid limit.
- Repository and installed-plugin real-engine checks pass: 1,200 CFM becomes 0.56633693184 m³/s; missing MCA stays missing, stale/overlapping/typo maps and output mutation flags fail, and source files remain unchanged.
- Literal row structures and IDs exactly match the earlier schedule-reader output for all three controlled rows. The new numericReview array is separate; no original evidence or review state is changed.
- Final iPad simulator acceptance passes in 12.123 seconds, opening the first row and verifying numeric airflow beside literal 1,200. The native screenshot was inspected. This exercises the production row UI through the synthetic schedule host, not a physical device or full engineering workflow.
- Mac compilation passes. Production package/source hashes match the final native snapshot. CI YAML and its 14 shell steps validate; the existing schedule verifier now asserts numeric output.
- Repository and installed plugin manifests validate. Installed version: `0.1.0+codex.20260910193119`.

The installed CLI initially terminated with SIGSEGV while encoding an array after an incremental link. A direct reproduction also failed. No active process was using that build directory; preserving it under `/tmp/gunnaire-loadsight-build-before-numeric-rebuild` and rebuilding in a fresh directory resolved the same installed-plugin verifier. This evidence is consistent with stale incremental build state; the compiler-level cause is not proven. Original project/drawing data was untouched.

## Reproduction

Run `swift test --package-path LoadSight` from the repository root. Run `python3 LoadSight/Tools/verify_equipment_schedules.py Plugins/gunnaire-ops /tmp/loadsight-numeric-check` with a new output directory. Native harness code is `Tools/fixtures/ScheduleNumericUITests.swift` with `EquipmentScheduleApp.swift` and the controlled fixture PDF/map injected into an isolated app copy.

Generated evidence remains excluded under `output/verification/schedule-numeric/`: shared/native/Mac logs, repository and installed-fresh summaries, original incremental crash report, screenshots and production source manifest. These are local checks; hosted CI and physical-device acceptance are not established.

## Remaining work

Sourced unit-convention selection is still needed for MBH, plain Btu/h, bare GPM and water-column pressure. Ranges, embedded units, dimensions, sound, locale-dependent numbers and additional aliases remain unresolved or literal. Automatic schedule detection, capacity/airflow plausibility, confirmed equipment/geometry association, complete engineering, REST/cloud, authenticated Ops publication and broad device acceptance remain open. Successful arithmetic is not engineering approval; row boundary/recognition warnings still apply.
