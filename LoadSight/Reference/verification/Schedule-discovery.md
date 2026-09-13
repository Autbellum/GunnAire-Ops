# Automatic schedule discovery — 2026-09-10

## Behavior and scope

`EquipmentScheduleDiscoverer` searches every imported page for supported horizontal header/tag alignment and proposes editable column maps. It requires no supplied map. The native Schedules workspace provides discovery, source overlays, header review and an authored map editor. The asynchronous SDK and read-only plugin commands use the same engine. Discovery does not create physical equipment, quantities, costs or approvals.

Candidates retain exact header/tag evidence, source/page identity, inferred body and column bounds, proposed fields/units, warnings and a deterministic ID. Unknown and duplicate headers remain visible and leave unmapped gaps. Lower-case unit labels preserve their source case. No MCA amperage unit or MBH/GPM convention is invented. Candidate preparation re-runs discovery against current evidence; native document/drawing sessions prevent applying an old review to a replacement project.

Method: `Schedule header and tag alignment discovery v1`. It groups words with more than 50% shared vertical overlap, then header cells with horizontal gaps no greater than the larger text height. Supported leftmost tag labels are TAG, EQUIPMENT TAG, MARK and EQUIPMENT MARK. Recognized aliases cover equipment, capacity, flow, coordination, dimensional and notes headers; see the engine's explicit alias table. At least two aligned tag rows are required, or one row with at least three recognized fields. Tag syntax is bounded letters, an optional separator, digits and optional trailing letter.

Proposed column edges bisect adjacent header-cell gaps; outer edges use two text heights of padding and page clipping. Tag runs stop at another supported tag header or a large gap (initially eight header heights; thereafter the larger of four heights or 1.8 times the preceding tag spacing). Body limits exclude the header and pad the last tag row. These are inspectable layout heuristics, not validated table ruling, engineering or physical-count methods. Inputs are bounded to 100,000 anchors per page and 500 candidates; cancellation is checked through completion. Original archives are validated once before discovery rather than rehashed for each proposal.

## Verified evidence

- **322 shared tests pass**, zero failures. Six discovery tests cover real-PDF mapping without map input, literal/missing cells, stable IDs, stale/forged candidates, unknown/duplicate headers, separate and adjacent tables, low-confidence anchors, rotated layouts and cancellation including the last page. Two preparation/session tests cover scope binding, cancelled result suppression, required authorship, package reopening and replacement-document rejection.
- **12 portable plugin boundary tests pass**. Discovery accepts no mutation, output, record-ID or mapping flags.
- Repository and installed real-engine checks find one table in the original synthetic schedule and read three rows from its proposal. Missing MCA remains absent; source bytes are unchanged.
- Native iPad discovery → source preview → map review → authored save → actual disk-package reopen → three-row reading **passes in 25.155 seconds** on the dedicated iOS 26.2 QA simulator.
- The repository plugin reads that actual native package through `schedule-discover-review` and `schedule-saved`. Its saved bounds/columns match rediscovery, authored history survives, the original PDF is byte-identical and the takeoff remains empty.
- Mac compilation passes (3.37 seconds). Both plugin manifests validate. CI YAML and **19 shell steps** pass syntax checks, including the new discovery verifier.
- Production source hashes match the native build copy. Final source-overlay and saved-row screenshots were visually inspected.

The original synthetic PDF is `Tests/LoadSightKitTests/Fixtures/EquipmentSchedule.pdf`, SHA-256 `08bb90c15f25f6847923419cb4965b51de012693c53b37ad6982005555e65824`. It is a controlled software fixture, not verified customer equipment. Installed plugin: `0.1.0+codex.20260910202251`.

Evidence is under `output/verification/schedule-discovery/`: test/build logs, production source manifest, repository/installed results, actual native package verification and native screenshots. The final screenshots are `C2F3DCB0-46EE-40B6-8E8A-574A845A36A3.png` (source) and `6AB5B830-D010-432E-ACE2-F230EFE3C47C.png` (saved rows).

## Reproduce

```sh
swift test --package-path LoadSight
python3 -m unittest discover -s Plugins/gunnaire-ops/tests -v
python3 LoadSight/Tools/verify_schedule_discovery.py Plugins/gunnaire-ops /tmp/new-discovery-evidence
python3 LoadSight/Tools/verify_native_discovery_package.py /absolute/native-fixture.loadsight Plugins/gunnaire-ops /tmp/new-native-discovery-evidence
```

Native harness: `Tools/fixtures/ScheduleMapAuthoringApp.swift` with only the original PDF bytes injected, and `Tools/fixtures/ScheduleDiscoveryUITests.swift`. It starts without a map. No signing, permissions, user drawings or external records are changed by the fixture workflow.

## Remaining scope

Stacked/merged headers, table linework, multiline continuations, unfamiliar tag/header forms, unusable OCR anchors and rotated layouts can be missed. Proposed body limits must be checked and expanded for missing rows/notes. Empty results do not prove absence of schedules. Full semantic extraction, confirmed plan/equipment associations, water-column conventions, complete engineering methods, authenticated cloud/Ops publication and broader device/export acceptance remain unfinished. Hosted CI and physical-device acceptance are not established by these local checks. The full application goal remains active.
