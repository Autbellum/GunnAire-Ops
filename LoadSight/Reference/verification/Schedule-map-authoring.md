# Native schedule map authoring and durable history

Verified locally on 2026-09-10. This milestone extends [mapped schedule reading](Equipment-schedules.md); it does not complete the application.

## Behavior and storage

The Schedules workspace can create, edit, read and remove named maps without hand-authoring JSON. A map records source/page, table body, column meanings, literal headers and units, text source, mapping basis, author and reason. The editor supports multiple table regions, precise numeric bounds and two-point preview tools. Changing source clears prior geometry and header evidence. Persistent labels identify saved coordinates. Invalid saves display an alert without discarding the draft; document-session and edit-fingerprint checks reject stale edits.

`ScheduleMapStorage.swift` preserves maps and full before/after revision snapshots. Core validates the basic storage schema and continuous history chain. `ProjectScheduleMaps.swift` applies strict typed request and current-source/geometry validation; historical requests retain schema validation without requiring removed historical drawings. Package, portable JSON and cold recovery preserve the records. Removal retains history. Edits reopen QA and leave quantities, costs and original bytes unchanged. Recorded authors are local declarations; history is consistency-checked, not authenticated or tamper-proof.

The CLI/plugin shares these operations: `schedule-map-review`, `schedule-saved`, `schedule.map.save` and `schedule.map.remove`. Edits require author, reason and current fingerprint and write to a new output path.

## Verification

- 269 shared Swift tests pass. Six map-storage tests cover package/JSON round trips, revision/removal history, stale edits, invalid geometry/source/metadata, corrupted storage, draft capture math and cold recovery.
- Eleven portable wrapper tests pass. Repository and installed real-engine verifiers create/read/revise/remove maps, reject stale and malformed edits and overwrite, and preserve original drawings and takeoff items.
- Mac compilation passes. Production package/source SHA-256 values match the isolated native acceptance build at handoff.
- The iPad iOS 26.2 simulator test passes in 72.413 seconds. It begins with no map, attempts an invalid save, corrects bounds and headers, reads three rows, writes an actual package to app Documents, reopens it and reads three rows again.
- The final screenshot was inspected: source/page selection and persistent Left/Bottom/Right/Top labels retain the saved coordinates. The lower Top row lies at the scroll viewport edge; its value is also asserted by the test and package verifier.
- Actual package verification confirms body `(40,520,480,160)`, tag column 40–160 and airflow column 320–430, literal TAG/CFM headers, one revision, empty takeoff and unchanged original PDF. The repository plugin reads RTU-1, EF-2 and RTU-1 from a portable representation of those actual package bytes.
- CI YAML parses and all 14 run steps pass shell syntax checking. Hosted CI has not run for these unpushed additions.

The controlled PDF SHA-256 is `08bb90c15f25f6847923419cb4965b51de012693c53b37ad6982005555e65824`. It contains synthetic values, not customer or manufacturer performance data. Repeated tags remain distinct review candidates and do not establish physical equipment counts.

## Reproduction and evidence

From the repository root:

```sh
swift test --package-path LoadSight
python3 -m unittest discover -s Plugins/gunnaire-ops/tests -v
python3 LoadSight/Tools/verify_schedule_map_storage.py Plugins/gunnaire-ops /tmp/loadsight-map-check
```

Use a new output directory for each verifier run. Native harness sources are `Tools/fixtures/ScheduleMapAuthoringApp.swift` and `Tools/fixtures/ScheduleMapAuthoringUITests.swift`; they substitute only the isolated test host and preload the controlled PDF. `Tools/verify_native_schedule_map_package.py` validates the resulting package. The initial UI attempt failed because its scroll gesture started over the keyboard; correcting the test gesture produced the recorded pass.

Local generated evidence is excluded from Git under `output/verification/schedule-map-authoring/`: source manifest, shared/native/Mac logs, repository and installed summaries, `Native-Authored-Map.loadsight`, portable JSON, native package verification and final acceptance screenshot. The installed plugin snapshot is `0.1.0+codex.20260910191732`.

## Acceptance limits

The native test uses typed bounds and an actual FileWrapper disk write/reopen in the harness. It does not establish Files-dialog, power-loss, Pencil/two-point interaction, multiple-region UI, multiwindow or physical-device acceptance. A nonfatal UIKitToolbar framework warning appeared in the harness run. Automatic table/header recognition, unit normalization, plausibility checks, real customer schedule acceptance, confirmed equipment associations, full engineering methods, REST/cloud and authenticated Ops publication remain open.
