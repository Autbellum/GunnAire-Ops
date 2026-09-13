# Mapped equipment schedules — 2026-09-10

## Delivered behavior

The shared SDK, CLI/plugin and native Schedules workspace read literal equipment-schedule rows from an explicitly supplied table body and column map. The mapping records the original file SHA-256, page identity, body/column bounds, header transcriptions, optional literal units, mapper name and evidence basis. The 25 supported column fields cover equipment identity, quantities, capacities, airflow/OA/ESP, water temperatures/flow, electrical coordination, weight/dimensions, sound, accessories and notes.

Rows are unreviewed candidates. The algorithm groups tag words by vertical overlap, constructs row bands between their baselines, and assigns only fully contained cell evidence. It reports boundary-crossing/gap text separately and warns that affected cells may be partial. Missing recognized cells and unmapped fields stay unknown. Literal values and units are not numerically converted. Row count and schedule quantity do not become physical takeoff counts.

Repeated tags remain distinct rows with reconciliation warnings. Exact case-insensitive equipment-tag occurrences outside the table body are possible source links. Tags without matching row text remain review candidates; neither result establishes an actual missing plan/schedule relationship.

`nativePDFWords` uses fresh PDFKit range selections from the original PDF. `recordedAnchors` retains existing text/OCR rectangles and never guesses how to split a cross-column anchor. Source bytes and project state remain unchanged. Row identities bind the region, mapping and extracted/source-link evidence; validation recomputes against current source data and rejects stale or forged results.

The native workspace imports a column map, reads it through a cancellable SDK operation and previews each row's recognized cell rectangles on the original page. Document/recognition changes invalidate displayed results. Results and mappings are currently transient; there is no accepted equipment/association register or native map-authoring editor yet. The import callback checks the document session before starting a scan.

The exact request schema and commands are in [plugin schedule guidance](../../../Plugins/gunnaire-ops/references/equipment-schedules.md). The SDK entry point is `LoadSightServicing.extractEquipmentSchedules`.

## Verification

- **263 shared XCTest tests pass** with the standard `swift test --package-path LoadSight` command; a separate scratch build also passes. Nine new tests cover the schedule reader and preparation controller.
- The controlled PDF yields three rows (`RTU-1`, `EF-2`, `RTU-1`), source-linked manufacturer/airflow text, unknown missing EF-2 MCA, repeated-tag warnings and the unmatched `AHU-9` occurrence. Tests cover boundary-crossing text, malformed/overlapping/stale maps, forged rows, low-confidence synthetic OCR, explicit zero versus unknown, unknown units and cancellation.
- **Ten wrapper tests pass**. Both repository and installed real-engine plugin checks preserve original PDF/map/project bytes, produce equivalent rows from direct PDF and portable JSON input, and reject stale sources, overlapping columns, unknown request keys and mutation/output flags.
- Portable and installed plugin manifests validate. Installed version `0.1.0+codex.20260910190518` matches personal source for the wrapper, schedule/status references and manifest.
- CI YAML parses and all **13** shell steps pass `bash -n`; the workflow now runs the schedule verifier. Hosted CI is not claimed.
- Mac application compilation passes. The production schedule UI is compiled in an isolated iPad application with a supplied controlled map. `EquipmentScheduleUITests.testRowSourceAndMissingCellReview` passes in **16.063 seconds** on the iPad Pro 11-inch (M5), iOS 26.2 simulator. It opens EF-2, previews source rectangles, reads the unknown MCA cell and returns to the row list.
- Both final screenshots were inspected: rectangles align to EF-2, Synthetic Inc and 250 CFM in the original PDF; the empty MCA remains explicitly unknown in the row sheet. The first UI run exposed a real empty-area hit-target problem. Adding a rectangle content shape makes the entire row tappable; the unchanged center-tap test then passes.
- At handoff, every production file in the native source manifest matches the working tree. The harness replaces only its isolated app entry point and UI-test source; it does not modify the production app entry point or signing configuration.

The initial character-by-character PDFKit localization experiment returned unusable rectangles for this controlled PDF. The final reader uses range selections, independently checked against the expected cells and native source overlays. This is observed behavior of the tested fixture/toolchain, not a general Apple bug claim. API reference: [Apple PDFPage documentation](https://developer.apple.com/documentation/pdfkit/pdfpage).

## Reproduce and inspect

```sh
swift test --package-path LoadSight
python3 -m unittest discover -s Plugins/gunnaire-ops/tests -v
python3 LoadSight/Tools/verify_equipment_schedules.py Plugins/gunnaire-ops /tmp/new-schedule-verification
python3 Plugins/gunnaire-ops/scripts/loadsight.py schedule-text LoadSight/Tests/LoadSightKitTests/Fixtures/EquipmentSchedule.pdf --schedule LoadSight/Tests/LoadSightKitTests/Fixtures/EquipmentScheduleMapping.json
```

`Tools/create_schedule_fixture.py` deterministically creates the synthetic PDF/map pair. Original PDF SHA-256: `08bb90c15f25f6847923419cb4965b51de012693c53b37ad6982005555e65824`. It contains no customer or manufacturer performance data.

Native harness templates are `Tools/fixtures/EquipmentScheduleApp.swift` and `EquipmentScheduleUITests.swift`. The app template expects `fixturePDFData` and `fixtureMappingData` loaded from the controlled fixtures; it supplies the map through the public production host interface. The recorded isolated project is `/tmp/loadsight-schedule-native/Native/LoadSight.xcodeproj`; final result bundle is `/tmp/loadsight-schedule-ui-final.xcresult`.

Local, Git-excluded evidence is under `output/verification/equipment-schedules/`: source manifest, handoff validation, shared/focused/native/Mac logs, native test JSON/screenshots and repository/installed plugin summaries. Retained source fixtures, tests and verifiers are Git-ready.

## Remaining acceptance and full scope

The native file-picker import flow is implemented but this test supplies the map through the host interface. Map authoring, imported-map recovery/persistence, real customer schedules, mixed/rotated/raster tables, merged cells, multiline/continuation headers, unit conversion and plausibility checks, confirmed plan/schedule associations and authenticated approvals remain open. Repeated tags and raw numeric text are not approved design inputs.

Complete load/distribution methods, geometry extraction, local REST/cloud services, authenticated Ops publication and broad physical-device acceptance remain in `BUILD_STATUS.md`. This milestone advances the extraction pipeline; it does not complete the original application objective.

## Subsequent milestone

Native map authoring and durable history are now implemented and locally verified. See [schedule map authoring](Schedule-map-authoring.md) for the newer 269-test snapshot and disk-save acceptance; earlier limitations above describe this reader milestone.
