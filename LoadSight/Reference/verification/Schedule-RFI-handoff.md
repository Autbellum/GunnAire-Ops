# Sourced schedule RFI handoff — 2026-09-10

Native schedule finding disclosures now offer an RFI draft action. Reviewers provide a question, known impact or uncertainty, and author. Saving creates an unanswered local RFI and linked JSON evidence attachment together. No message is sent, answer invented, equipment association approved or takeoff quantity changed.

## Evidence contract

`ScheduleRFI.swift` re-extracts the source row and validates drawing evidence before selecting the current finding. The human-readable RFI source includes row and finding IDs, original SHA-256, page, bounds, mapping author/basis, affected literal cells and units, conditional finding basis and attachment SHA-256. `ScheduleRFIEvidence` schema 1 preserves the complete row (including mapped headers, bounds, all cells, recognition rectangles and possible tag links), selected recomputed finding, method and limitations.

The RFI and attachment are committed through a project copy only after both succeed. Existing RFI history and attachment fingerprint validation apply. The snapshot is a historical local record, not authenticated approval or proof that the current drawing still matches it. Later drawing/map changes do not rewrite the earlier snapshot. Native saving uses the drawing-review session captured at row selection; a replacement document or changed drawing archive cannot receive the pending draft.

`schedule.rfi.create` uses the existing plugin `apply` command. Required fields are operation, author, request (complete strict schedule map), rowID, findingID, question and impact. The engine recomputes the row and finding; arbitrary supplied findings are not accepted. The wrapper requires a new output path. Local RFI editing, resolution, export and history continue through their existing workflows; DOCX lists attachments without embedding their bytes.

## Model and plugin verification

The combined source passes 297 tests, including four new RFI tests: package/portable JSON retention of the unanswered question and exact attachment, invalid source/finding/question/author atomic rejection, structured current/stale/unknown-key cases, and replacement-document session protection. Concurrent drawing-review session changes are included and preserved.

Repository and installed plugin checks pass against the controlled consistency PDF: snapshot row equals the extracted original row, attachment SHA matches its bytes and source reference, RFI remains Open with an empty answer, original drawing and item arrays remain unchanged, and stale/invalid/overwrite requests fail. Both plugin runs retain the same evidence SHA `d4cf6b84b7176fe42b8af32f405a42bf7291f413482f83c1ff7b468f3037d2f5`. Installed plugin: `0.1.0+codex.20260910194209`.

Mac compilation passes. CI adds `verify_schedule_rfi.py` and its 16 shell steps pass local syntax checks. Hosted CI is unverified. The first combined build encountered concurrent source changes and a SwiftUI type-checking limit; extracting the additional-review view reduced that expression and the rebuilt shared suite passed.

## Native acceptance and reproduction

The final native test passes in **27.427 seconds**, including saved-field disabling and finding the new question in the RFI register. Production source hashes match the isolated build. Saving now dismisses the keyboard and disables saved draft inputs, so later typing cannot appear to revise the recorded question.

The native test uses `Tools/fixtures/ScheduleRFIApp.swift` with controlled PDF/map bytes and `ScheduleRFUITests.swift`, in an isolated copy of the production package. It opens an airflow finding, enters the question/impact/author, saves, then opens the full workspace's RFI register. The first interaction attempt could not locate the visible button by its nested identifier; video inspection established visibility and the test was updated to query its displayed label. Accessibility inspection also showed the multiline inputs are TextField elements; the test was corrected from TextView queries.

Run from the repository root:

```sh
swift test --package-path LoadSight
python3 LoadSight/Tools/verify_schedule_rfi.py Plugins/gunnaire-ops /tmp/loadsight-schedule-rfi-check
```

Use a new verifier output directory. Generated logs, snapshots, native attachments, source hashes and plugin outputs remain excluded under `output/verification/schedule-rfi/`. This milestone does not establish physical-device, remote delivery, authenticated identity, full engineering, automatic extraction, confirmed equipment associations or REST/cloud/Ops publication acceptance. The complete application objective remains active.
